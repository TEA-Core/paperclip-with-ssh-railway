import fs from "node:fs";

const owner = "paperclipai";
const repo = "paperclip";
const token = process.env.GITHUB_TOKEN;

if (!token) {
  console.error("Missing GITHUB_TOKEN");
  process.exit(2);
}

async function gh(path) {
  const url = `https://api.github.com${path}`;
  const res = await fetch(url, {
    headers: {
      authorization: `Bearer ${token}`,
      accept: "application/vnd.github+json",
      "user-agent": "paperclip-railway-template-bot",
    },
  });
  if (!res.ok) {
    throw new Error(`GitHub API ${res.status}: ${await res.text()}`);
  }
  return res.json();
}

function readCurrentRef(dockerfile) {
  const m = dockerfile.match(/\nARG PAPERCLIP_REF=([^\n]+)\n/);
  return m ? m[1].trim() : null;
}

function replaceRef(dockerfile, next) {
  const re = /\nARG PAPERCLIP_REF=([^\n]+)\n/;
  if (!re.test(dockerfile)) throw new Error("Could not find PAPERCLIP_REF line");
  return dockerfile.replace(re, `\nARG PAPERCLIP_REF=${next}\n`);
}

const latest = await gh(`/repos/${owner}/${repo}/releases/latest`);
const latestTag = latest.tag_name;
if (!latestTag) throw new Error("No tag_name in latest release response");

const dockerPath = "Dockerfile";
const docker = fs.readFileSync(dockerPath, "utf8");
const currentRef = readCurrentRef(docker);
if (!currentRef) throw new Error("Could not parse current PAPERCLIP_REF");

console.log(`current=${currentRef} latest=${latestTag}`);

if (currentRef === latestTag) {
  console.log("No update needed.");
  process.exit(0);
}

fs.writeFileSync(dockerPath, replaceRef(docker, latestTag));
console.log(`Updated ${dockerPath} to ${latestTag}`);
