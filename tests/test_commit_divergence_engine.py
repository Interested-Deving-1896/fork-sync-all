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

if __name__ == "__main__": unittest.main()
