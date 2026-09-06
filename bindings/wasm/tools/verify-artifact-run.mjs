import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

export function verifyArtifactRun(run, jobs, expectedCommit) {
  if (run.path !== ".github/workflows/release-artifacts.yml" || run.head_sha !== expectedCommit ||
      run.status !== "completed" || run.conclusion !== "success") {
    throw new Error("Release artifacts must come from a successful Release Artifacts run at the current commit");
  }
  const browser = jobs.filter(job => /(?:^|\/ )WASM browser package$/.test(job.name));
  if (browser.length !== 1 || browser[0].conclusion !== "success") {
    throw new Error("Release artifact run must include a successful WASM browser package job");
  }
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [, , runFile, jobsFile, commit] = process.argv;
  const pages = JSON.parse(readFileSync(jobsFile, "utf8"));
  verifyArtifactRun(JSON.parse(readFileSync(runFile, "utf8")), pages.flatMap(page => page.jobs), commit);
  console.log("Artifact workflow and WASM browser gate verified");
}
