import importlib.util, json, subprocess, tempfile, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("commit_divergence_engine", ROOT / "scripts" / "commit_divergence_engine.py")
MODULE = importlib.util.module_from_spec(SPEC); assert SPEC.loader; SPEC.loader.exec_module(MODULE)

class CommitDivergenceTests(unittest.TestCase):
    def comparison(self, status, ahead, behind):
        return {"base_sha":"base","head_sha":"head","status":status,"ahead_by":ahead,"behind_by":behind,"merge_base_sha":"merge"}
    def test_head_ahead_direction(self): self.assertEqual(MODULE.classify("base","head",self.comparison("ahead",5,0)),"head_ahead")
    def test_base_ahead_direction(self): self.assertEqual(MODULE.classify("base","head",self.comparison("behind",0,10)),"base_ahead")
    def test_diverged(self): self.assertEqual(MODULE.classify("base","head",self.comparison("diverged",5,10)),"diverged")
    def test_identical(self): self.assertEqual(MODULE.classify("same","same",None),"identical")
    def test_unrelated(self): self.assertEqual(MODULE.classify("base","head",self.comparison("unrelated",0,0)),"unrelated")
    def test_rejects_moved_sha(self):
        c=self.comparison("ahead",5,0); c["head_sha"]="moved"
        self.assertEqual(MODULE.classify("base","head",c),"unknown")
    def test_rejects_inconsistent_counts(self): self.assertEqual(MODULE.classify("base","head",self.comparison("ahead",5,2)),"unknown")
    def test_patch_id_unique_candidate_only(self):
        result=MODULE.correlate_patch_ids([{"side":"base","sha":"b1","patch_id":"p1"},{"side":"head","sha":"h1","patch_id":"p1"}])
        self.assertEqual(result[0]["confidence"],"candidate")
        self.assertIn("candidate",result[0]["meaning"])
    def test_duplicate_patch_ids_ambiguous(self):
        result=MODULE.correlate_patch_ids([{"side":"base","sha":"b1","patch_id":"p"},{"side":"base","sha":"b2","patch_id":"p"},{"side":"head","sha":"h1","patch_id":"p"}])
        self.assertEqual(result[0]["confidence"],"ambiguous")
    def test_divergence_never_plans_rewrite(self):
        r=MODULE.analyze({"base_sha":"base","head_sha":"head","comparison":self.comparison("diverged",5,10)})
        self.assertEqual(r["recommendation"]["action"],"manual_reconciliation")
        self.assertEqual(r["recommendation"]["execution"],"not_performed")
    def test_incomplete_fails_closed(self):
        r=MODULE.analyze({"base_sha":"base","head_sha":"head","comparison":self.comparison("ahead",1,0),"incomplete_reasons":["pagination incomplete"]})
        self.assertEqual(r["recommendation"]["action"],"manual_review")
    def test_cli_json(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/"snapshot.json"; p.write_text(json.dumps({"base_sha":"x","head_sha":"x"}))
            out=subprocess.run(["python3",str(ROOT/"scripts/commit_divergence_engine.py"),str(p)],capture_output=True,text=True,check=True)
        self.assertEqual(json.loads(out.stdout)["relationship"],"identical")


    def topology(self):
        return {
            "schema_version": 1, "provider": "github", "repository": "owner/repo",
            "status": "complete", "read_only": True, "incomplete_reasons": [],
            "pull_requests": [{
                "number": 42, "base_repo": "owner/repo", "head_repo": "owner/repo",
                "base_ref": "main", "head_ref": "topic", "base_sha": "base", "head_sha": "head",
                "comparison_base_sha": "base", "comparison_head_sha": "head",
                "comparison_consistent": True, "comparison_status": "ahead",
                "ahead_by": 3, "behind_by": 0, "html_url": "https://github.com/owner/repo/pull/42"
            }]
        }
    def test_branch_topology_adapter_exact_complete(self):
        result = MODULE.analyze_branch_topology(self.topology())
        self.assertEqual(result["status"], "complete")
        self.assertEqual(result["reports"][0]["relationship"], "head_ahead")
        self.assertEqual(result["reports"][0]["pull_request"], 42)
        self.assertEqual(result["execution"], "not_performed")
    def test_branch_topology_mismatched_comparison_sha_fails_closed(self):
        snap = self.topology()
        snap["pull_requests"][0]["comparison_head_sha"] = "moved"
        result = MODULE.analyze_branch_topology(snap)
        self.assertEqual(result["status"], "incomplete_or_unverified")
        self.assertEqual(result["reports"][0]["relationship"], "unknown")
        self.assertFalse(result["reports"][0]["exact_comparison_verified"])
    def test_branch_topology_incomplete_snapshot_fails_closed(self):
        snap = self.topology()
        snap["status"] = "incomplete"
        snap["incomplete_reasons"] = ["pagination failed"]
        result = MODULE.analyze_branch_topology(snap)
        self.assertEqual(result["status"], "incomplete_or_unverified")
        self.assertEqual(result["reports"][0]["recommendation"]["action"], "manual_review")
    def test_branch_topology_unknown_relationship_fails_closed(self):
        snap = self.topology()
        snap["pull_requests"][0]["comparison_status"] = "unknown"
        snap["pull_requests"][0]["ahead_by"] = None
        snap["pull_requests"][0]["behind_by"] = None
        result = MODULE.analyze_branch_topology(snap)
        self.assertEqual(result["reports"][0]["relationship"], "unknown")
        self.assertEqual(result["reports"][0]["recommendation"]["action"], "manual_review")
    def test_branch_topology_fork_repository_mismatch_fails_closed(self):
        snap = self.topology()
        snap["pull_requests"][0]["head_repo"] = "contributor/fork"
        result = MODULE.analyze_branch_topology(snap)
        self.assertEqual(result["status"], "incomplete_or_unverified")
        self.assertTrue(result["reports"][0]["incomplete_reasons"])
        self.assertEqual(result["reports"][0]["recommendation"]["action"], "manual_review")
    def test_branch_topology_schema_version_mismatch_fails_closed(self):
        snap = self.topology()
        snap["schema_version"] = 2
        result = MODULE.analyze_branch_topology(snap)
        self.assertEqual(result["status"], "incomplete_or_unverified")

if __name__ == "__main__": unittest.main()
