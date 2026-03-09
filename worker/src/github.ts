/**
 * GitHub API integration for committing scan data
 */

export interface CommitData {
  path: string;
  content: string;
  message: string;
}

interface Env {
  GITHUB_TOKEN: string;
  GITHUB_REPO: string;
  GITHUB_BRANCH: string;
}

/**
 * Read raw file content from GitHub at the target branch.
 * Returns null when the file does not exist.
 */
export async function getGitHubFileContent(
  env: Env,
  path: string
): Promise<string | null> {
  const [owner, repo] = env.GITHUB_REPO.split('/');
  const branch = env.GITHUB_BRANCH || 'main';
  const encodedPath = path
    .split('/')
    .map((segment) => encodeURIComponent(segment))
    .join('/');
  const fileUrl =
    `https://api.github.com/repos/${owner}/${repo}/contents/${encodedPath}` +
    `?ref=${encodeURIComponent(branch)}`;

  const response = await fetch(fileUrl, {
    headers: {
      Authorization: `token ${env.GITHUB_TOKEN}`,
      'User-Agent': 'mesh-utility-worker',
      Accept: 'application/vnd.github.raw+json',
    },
  });

  if (response.status === 404) {
    return null;
  }

  if (!response.ok) {
    throw new Error(`Failed to fetch file content: ${response.statusText}`);
  }

  return await response.text();
}

/**
 * Commit a file to GitHub repository
 */
export async function commitToGitHub(env: Env, data: CommitData): Promise<void> {
  const [owner, repo] = env.GITHUB_REPO.split('/');
  const branch = env.GITHUB_BRANCH || 'main';

  // 1. Get reference to branch
  const refUrl = `https://api.github.com/repos/${owner}/${repo}/git/ref/heads/${branch}`;
  const refResponse = await fetch(refUrl, {
    headers: {
      Authorization: `token ${env.GITHUB_TOKEN}`,
      'User-Agent': 'mesh-utility-worker',
      Accept: 'application/vnd.github.v3+json',
    },
  });

  if (!refResponse.ok) {
    throw new Error(`Failed to get branch ref: ${refResponse.statusText}`);
  }

  const refData = await refResponse.json() as { object: { sha: string } };
  const latestCommitSha = refData.object.sha;

  // 2. Get the commit to find the tree
  const commitUrl = `https://api.github.com/repos/${owner}/${repo}/git/commits/${latestCommitSha}`;
  const commitResponse = await fetch(commitUrl, {
    headers: {
      Authorization: `token ${env.GITHUB_TOKEN}`,
      'User-Agent': 'mesh-utility-worker',
      Accept: 'application/vnd.github.v3+json',
    },
  });

  if (!commitResponse.ok) {
    throw new Error(`Failed to get commit: ${commitResponse.statusText}`);
  }

  const commitData = await commitResponse.json() as { tree: { sha: string } };
  const baseTreeSha = commitData.tree.sha;

  // 3. Create blob for the file content
  const blobUrl = `https://api.github.com/repos/${owner}/${repo}/git/blobs`;
  const blobResponse = await fetch(blobUrl, {
    method: 'POST',
    headers: {
      Authorization: `token ${env.GITHUB_TOKEN}`,
      'User-Agent': 'mesh-utility-worker',
      'Content-Type': 'application/json',
      Accept: 'application/vnd.github.v3+json',
    },
    body: JSON.stringify({
      content: data.content,
      encoding: 'utf-8',
    }),
  });

  if (!blobResponse.ok) {
    throw new Error(`Failed to create blob: ${blobResponse.statusText}`);
  }

  const blobData = await blobResponse.json() as { sha: string };

  // 4. Create new tree with the blob
  const treeUrl = `https://api.github.com/repos/${owner}/${repo}/git/trees`;
  const treeResponse = await fetch(treeUrl, {
    method: 'POST',
    headers: {
      Authorization: `token ${env.GITHUB_TOKEN}`,
      'User-Agent': 'mesh-utility-worker',
      'Content-Type': 'application/json',
      Accept: 'application/vnd.github.v3+json',
    },
    body: JSON.stringify({
      base_tree: baseTreeSha,
      tree: [
        {
          path: data.path,
          mode: '100644',
          type: 'blob',
          sha: blobData.sha,
        },
      ],
    }),
  });

  if (!treeResponse.ok) {
    throw new Error(`Failed to create tree: ${treeResponse.statusText}`);
  }

  const treeData = await treeResponse.json() as { sha: string };

  // 5. Create new commit
  const newCommitUrl = `https://api.github.com/repos/${owner}/${repo}/git/commits`;
  const newCommitResponse = await fetch(newCommitUrl, {
    method: 'POST',
    headers: {
      Authorization: `token ${env.GITHUB_TOKEN}`,
      'User-Agent': 'mesh-utility-worker',
      'Content-Type': 'application/json',
      Accept: 'application/vnd.github.v3+json',
    },
    body: JSON.stringify({
      message: data.message,
      tree: treeData.sha,
      parents: [latestCommitSha],
    }),
  });

  if (!newCommitResponse.ok) {
    throw new Error(`Failed to create commit: ${newCommitResponse.statusText}`);
  }

  const newCommitData = await newCommitResponse.json() as { sha: string };

  // 6. Update branch reference
  const updateRefUrl = `https://api.github.com/repos/${owner}/${repo}/git/refs/heads/${branch}`;
  const updateRefResponse = await fetch(updateRefUrl, {
    method: 'PATCH',
    headers: {
      Authorization: `token ${env.GITHUB_TOKEN}`,
      'User-Agent': 'mesh-utility-worker',
      'Content-Type': 'application/json',
      Accept: 'application/vnd.github.v3+json',
    },
    body: JSON.stringify({
      sha: newCommitData.sha,
    }),
  });

  if (!updateRefResponse.ok) {
    throw new Error(`Failed to update ref: ${updateRefResponse.statusText}`);
  }
}

/**
 * Batch multiple files into a single commit
 */
export async function batchCommitToGitHub(
  env: Env,
  files: Array<{ path: string; content: string }>,
  message: string
): Promise<void> {
  const [owner, repo] = env.GITHUB_REPO.split('/');
  const branch = env.GITHUB_BRANCH || 'main';

  // Get current branch state
  const refUrl = `https://api.github.com/repos/${owner}/${repo}/git/ref/heads/${branch}`;
  const refResponse = await fetch(refUrl, {
    headers: {
      Authorization: `token ${env.GITHUB_TOKEN}`,
      'User-Agent': 'mesh-utility-worker',
      Accept: 'application/vnd.github.v3+json',
    },
  });

  if (!refResponse.ok) {
    throw new Error(`Failed to get branch ref: ${refResponse.statusText}`);
  }

  const refData = await refResponse.json() as { object: { sha: string } };
  const latestCommitSha = refData.object.sha;

  // Get base tree
  const commitUrl = `https://api.github.com/repos/${owner}/${repo}/git/commits/${latestCommitSha}`;
  const commitResponse = await fetch(commitUrl, {
    headers: {
      Authorization: `token ${env.GITHUB_TOKEN}`,
      'User-Agent': 'mesh-utility-worker',
      Accept: 'application/vnd.github.v3+json',
    },
  });

  if (!commitResponse.ok) {
    throw new Error(`Failed to get commit: ${commitResponse.statusText}`);
  }

  const commitData = await commitResponse.json() as { tree: { sha: string } };
  const baseTreeSha = commitData.tree.sha;

  // Create blobs for all files in parallel
  const blobPromises = files.map(async (file) => {
    const blobUrl = `https://api.github.com/repos/${owner}/${repo}/git/blobs`;
    const blobResponse = await fetch(blobUrl, {
      method: 'POST',
      headers: {
        Authorization: `token ${env.GITHUB_TOKEN}`,
        'User-Agent': 'mesh-utility-worker',
        'Content-Type': 'application/json',
        Accept: 'application/vnd.github.v3+json',
      },
      body: JSON.stringify({
        content: file.content,
        encoding: 'utf-8',
      }),
    });

    if (!blobResponse.ok) {
      throw new Error(`Failed to create blob: ${blobResponse.statusText}`);
    }

    const blobData = await blobResponse.json() as { sha: string };
    return {
      path: file.path,
      mode: '100644',
      type: 'blob',
      sha: blobData.sha,
    };
  });

  const treeItems = await Promise.all(blobPromises);

  // Create tree with all blobs
  const treeUrl = `https://api.github.com/repos/${owner}/${repo}/git/trees`;
  const treeResponse = await fetch(treeUrl, {
    method: 'POST',
    headers: {
      Authorization: `token ${env.GITHUB_TOKEN}`,
      'User-Agent': 'mesh-utility-worker',
      'Content-Type': 'application/json',
      Accept: 'application/vnd.github.v3+json',
    },
    body: JSON.stringify({
      base_tree: baseTreeSha,
      tree: treeItems,
    }),
  });

  if (!treeResponse.ok) {
    throw new Error(`Failed to create tree: ${treeResponse.statusText}`);
  }

  const treeData = await treeResponse.json() as { sha: string };

  // Create commit
  const newCommitUrl = `https://api.github.com/repos/${owner}/${repo}/git/commits`;
  const newCommitResponse = await fetch(newCommitUrl, {
    method: 'POST',
    headers: {
      Authorization: `token ${env.GITHUB_TOKEN}`,
      'User-Agent': 'mesh-utility-worker',
      'Content-Type': 'application/json',
      Accept: 'application/vnd.github.v3+json',
    },
    body: JSON.stringify({
      message,
      tree: treeData.sha,
      parents: [latestCommitSha],
    }),
  });

  if (!newCommitResponse.ok) {
    throw new Error(`Failed to create commit: ${newCommitResponse.statusText}`);
  }

  const newCommitData = await newCommitResponse.json() as { sha: string };

  // Update branch reference
  const updateRefUrl = `https://api.github.com/repos/${owner}/${repo}/git/refs/heads/${branch}`;
  const updateRefResponse = await fetch(updateRefUrl, {
    method: 'PATCH',
    headers: {
      Authorization: `token ${env.GITHUB_TOKEN}`,
      'User-Agent': 'mesh-utility-worker',
      'Content-Type': 'application/json',
      Accept: 'application/vnd.github.v3+json',
    },
    body: JSON.stringify({
      sha: newCommitData.sha,
    }),
  });

  if (!updateRefResponse.ok) {
    throw new Error(`Failed to update ref: ${updateRefResponse.statusText}`);
  }
}
