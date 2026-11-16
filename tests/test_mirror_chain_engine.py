"""Contract tests for the provider-neutral mirror-chain provisioner."""
from __future__ import annotations

import unittest

from engines.mirror_chain import (
    ChainEdge,
    ChainSpec,
    Provisioner,
    ProvisioningError,
    RepositoryRef,
    RepositoryState,
    Strategy,
)


class FakeProvider:
    def __init__(self, states=None, *, create_conflict=False):
        self.states = dict(states or {})
        self.create_conflict = create_conflict
        self.created = []

    def resolve(self, ref):
        return self.states.get(
            ref.coordinate, RepositoryState(ref=ref, exists=False)
        )

    def create_native_fork(self, source, destination):
        self.created.append(("fork", source.ref.coordinate, destination.coordinate))
        if self.create_conflict:
            # Simulate a name collision/redirect discovered after planning.
            return RepositoryState(
                ref=RepositoryRef(destination.provider, destination.owner, destination.name, "wrong-id"),
                exists=True,
                is_fork=False,
            )
        state = RepositoryState(
            ref=RepositoryRef(
                destination.provider, destination.owner, destination.name,
                f"id:{destination.owner}/{destination.name}",
            ),
            exists=True,
            is_fork=True,
            parent_id=source.ref.repository_id,
        )
        self.states[destination.coordinate] = state
        return state

    def create_clone_mirror(self, source, destination):
        self.created.append(("clone", source.ref.coordinate, destination.coordinate))
        state = RepositoryState(
            ref=RepositoryRef(
                destination.provider, destination.owner, destination.name,
                f"id:{destination.owner}/{destination.name}",
            ),
            exists=True,
            is_fork=False,
            source_id=source.ref.repository_id,
        )
        self.states[destination.coordinate] = state
        return state


class MirrorChainEngineTests(unittest.TestCase):
    def setUp(self):
        self.provider = FakeProvider()
        self.canonical = RepositoryRef("github", "canonical", "project", "root-id")
        self.osp = RepositoryRef("github", "osp", "project")
        self.ooc = RepositoryRef("github", "ooc", "project")
        self.provider.states[self.canonical.coordinate] = RepositoryState(
            self.canonical, exists=True
        )
        self.engine = Provisioner({"github": self.provider})

    def spec(self, edges=None):
        return ChainSpec(
            canonical=self.canonical,
            edges=tuple(edges if edges is not None else (
                ChainEdge(self.canonical, self.osp),
                ChainEdge(self.osp, self.ooc),
            )),
        )

    def test_plan_is_read_only_and_orders_chain(self):
        actions = self.engine.plan(self.spec())
        self.assertEqual([a.action for a in actions], ["create", "create"])
        self.assertEqual(len(self.provider.created), 0)
        self.assertEqual(actions[0].destination, self.osp.coordinate)
        self.assertEqual(actions[1].source, self.osp.coordinate)

    def test_dry_run_apply_is_read_only(self):
        actions = self.engine.apply(self.spec(), dry_run=True)
        self.assertEqual(len(actions), 2)
        self.assertEqual(self.provider.created, [])

    def test_apply_creates_native_fork_chain(self):
        self.engine.apply(self.spec(), dry_run=False)
        self.assertEqual(len(self.provider.created), 2)
        self.assertEqual(self.provider.created[0][0], "fork")
        self.assertEqual(self.provider.created[1][1], self.osp.coordinate)
        self.assertTrue(self.provider.resolve(self.ooc).exists)

    def test_existing_independent_destination_fails_closed(self):
        self.provider.states[self.osp.coordinate] = RepositoryState(
            self.osp, exists=True, is_fork=False
        )
        with self.assertRaisesRegex(ProvisioningError, "identity/ancestry conflict"):
            self.engine.plan(self.spec())
        self.assertEqual(self.provider.created, [])

    def test_existing_fork_with_wrong_parent_fails_closed(self):
        self.provider.states[self.osp.coordinate] = RepositoryState(
            RepositoryRef("github", "osp", "project", "osp-id"),
            exists=True, is_fork=True, parent_id="unrelated-root",
        )
        with self.assertRaises(ProvisioningError):
            self.engine.plan(self.spec())

    def test_missing_canonical_fails_closed(self):
        self.provider.states[self.canonical.coordinate] = RepositoryState(
            self.canonical, exists=False
        )
        with self.assertRaisesRegex(ProvisioningError, "canonical repository"):
            self.engine.plan(self.spec())

    def test_cycle_is_rejected(self):
        spec = self.spec((
            ChainEdge(self.canonical, self.osp),
            ChainEdge(self.osp, self.ooc),
            ChainEdge(self.ooc, self.osp),
        ))
        with self.assertRaisesRegex(ProvisioningError, "cycle"):
            self.engine.plan(spec)

    def test_disconnected_destination_is_rejected(self):
        stranger = RepositoryRef("github", "elsewhere", "project")
        spec = self.spec((ChainEdge(stranger, self.ooc),))
        with self.assertRaisesRegex(ProvisioningError, "not reachable"):
            self.engine.plan(spec)

    def test_duplicate_destination_is_rejected(self):
        spec = self.spec((
            ChainEdge(self.canonical, self.osp),
            ChainEdge(self.canonical, self.osp, Strategy.CLONE_MIRROR),
        ))
        with self.assertRaisesRegex(ProvisioningError, "duplicate destination"):
            self.engine.plan(spec)

    def test_apply_rechecks_destination_before_write(self):
        self.provider.create_conflict = True
        with self.assertRaisesRegex(ProvisioningError, "identity/ancestry conflict"):
            self.engine.apply(self.spec((ChainEdge(self.canonical, self.osp),)), dry_run=False)

    def test_clone_mirror_uses_distinct_strategy(self):
        self.engine.apply(
            self.spec((ChainEdge(self.canonical, self.osp, Strategy.CLONE_MIRROR),)),
            dry_run=False,
        )
        self.assertEqual(self.provider.created[0][0], "clone")
        state = self.provider.resolve(self.osp)
        self.assertFalse(state.is_fork)
        self.assertEqual(state.source_id, "root-id")



    def test_existing_clone_mirror_is_kept_only_when_source_id_matches(self):
        self.provider.states[self.osp.coordinate] = RepositoryState(
            RepositoryRef("github", "osp", "project", "osp-id"),
            exists=True,
            is_fork=False,
            source_id="root-id",
        )
        spec = self.spec((ChainEdge(self.canonical, self.osp, Strategy.CLONE_MIRROR),))
        self.assertEqual(self.engine.plan(spec)[0].action, "keep")

    def test_existing_clone_mirror_with_wrong_source_fails_closed(self):
        self.provider.states[self.osp.coordinate] = RepositoryState(
            RepositoryRef("github", "osp", "project", "osp-id"),
            exists=True,
            is_fork=False,
            source_id="unrelated-root",
        )
        spec = self.spec((ChainEdge(self.canonical, self.osp, Strategy.CLONE_MIRROR),))
        with self.assertRaisesRegex(ProvisioningError, "clone-mirror identity/source conflict"):
            self.engine.plan(spec)

    def test_redirected_destination_identity_fails_closed(self):
        self.provider.states[self.osp.coordinate] = RepositoryState(
            RepositoryRef("github", "OpenOS-Project-OSP", "Interested-Deving-1896", "profile-id"),
            exists=True,
            is_fork=True,
            parent_id="root-id",
        )
        with self.assertRaisesRegex(ProvisioningError, "redirect/identity conflict"):
            self.engine.plan(self.spec((ChainEdge(self.canonical, self.osp),)))

    def test_apply_orders_unordered_edges_from_verified_sources(self):
        spec = self.spec((
            ChainEdge(self.osp, self.ooc),
            ChainEdge(self.canonical, self.osp),
        ))
        self.engine.apply(spec, dry_run=False)
        self.assertEqual(len(self.provider.created), 2)
        self.assertEqual(self.provider.created[0][2], self.osp.coordinate)
        self.assertEqual(self.provider.created[1][2], self.ooc.coordinate)


    def test_apply_requires_immutable_source_id_before_creating(self):
        self.provider.states[self.canonical.coordinate] = RepositoryState(
            RepositoryRef("github", "canonical", "project"),
            exists=True,
        )
        with self.assertRaisesRegex(ProvisioningError, "source immutable repository ID"):
            self.engine.apply(self.spec((ChainEdge(self.canonical, self.osp),)), dry_run=False)
        self.assertEqual(self.provider.created, [])

if __name__ == "__main__":
    unittest.main()
