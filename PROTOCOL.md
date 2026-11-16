# Overwatch review protocol

A reviewer has gone over this branch in Neovim with overwatch.nvim and left their feedback on the pull request as comments. There are three shapes:

1. **Line comments**: ordinary review threads on lines the PR changed.
2. **File comments**: review threads on a whole file, used for lines *outside* the PR's diff. They start with a link to the exact lines and the code itself, then the reviewer's text:

   ````markdown
   [`path/to/file.py#L340-L349`](https://github.com/OWNER/REPO/blob/<sha>/path/to/file.py#L340-L349)
   ```python
   ...the code those lines held...
   ```

   Does this need to be its own function?
   ````

3. **Conversation comments**: comments in the PR's main conversation. Some have the same link-and-code shape, for code in files the PR doesn't touch (GitHub doesn't allow review comments on those files). Others are about the PR as a whole.

Your job is to work through every item the way a competent engineer answers a senior reviewer. Fix what's wrong. Push back where you disagree. Ask when you're stuck. Leave a written trail on the PR, where the reviewer will look.

## 0. Repo rules win

If this repository has its own agent instructions for handling review feedback, they override this file wherever the two conflict. Check AGENTS.md, CLAUDE.md, and any skills or commands about PR feedback (for example `take-feedback`). They take precedence on:

- the identity to commit and push as (for example, a bot wrapper script);
- how to commit and push;
- how to reply to PR threads.

Follow them exactly.

If the repo defines no write identity, use the default git and `gh` identity. Start every reply you post with `🤖 Agent:` so the reviewer can tell your words from theirs.

## 1. Enumerate everything before touching code

Do not start fixing until you have read every item in full.

```bash
PR=$(gh pr view --json number -q .number)
gh api graphql -F owner='{owner}' -F repo='{repo}' -F pr=$PR -f query='
query($owner:String!, $repo:String!, $pr:Int!) {
  repository(owner:$owner, name:$repo) {
    pullRequest(number:$pr) {
      reviewThreads(first:100) {
        nodes {
          id isResolved isOutdated subjectType path line startLine
          comments(first:50) { nodes { databaseId author { login } body } }
        }
      }
      comments(last:100) { nodes { id databaseId url author { login } body isMinimized } }
    }
  }
}'
```

**Review threads** (`reviewThreads`): a thread is **open** if `isResolved` is `false` and its last comment isn't yours.

- `subjectType: FILE` threads are file comments. Their lines are in the link that starts the first comment. The code block shows what those lines held, so use it to find the code if it has moved.
- `isOutdated: true` means the code under the comment has changed since. Still address it, and say in your reply that the line moved.

**Conversation comments** (`comments`): every comment from the reviewer is a work item, except ones hidden as resolved (`isMinimized: true`). A comment is **open** if no later comment of yours replies to it, which you do by linking its `url` (see step 5). A reviewer comment that starts with `Re: <url>` is a follow-up to the comment at that url. Ignore comments from anyone else, such as CI bots.

Read each item in full, including every reply. The latest reviewer comment is the current ask.

Put every open item into one todo list. That list is the contract: you are not done until every item on it has an outcome.

## 2. Triage each item

Every item ends in exactly one outcome:

| Outcome | When |
| --- | --- |
| **Fixed** | You made the change and verified it |
| **Disagreed** | You think the feedback is wrong, or the tradeoff isn't worth it |
| **Blocked** | You can't proceed without a decision or information |

Silently skipping an item is not an outcome.

Before writing any code, cross-check the whole list. If two items pull in opposite directions, that's Blocked, not a judgement call for you to make quietly.

## 3. Check the blast radius before calling anything Fixed

Feedback points at one spot, but it is usually about a *class* of problem.

- **Is this one instance or a pattern?** Search the repo for the same pattern. Either fix every occurrence, or say explicitly why you scoped the fix to one.
- **Did you change a signature, type or contract?** Find and update every caller.
- **Run the full test suite**, not just the tests near the change.

## 4. Commit

- **Unrelated items get their own commit.** An item about code unrelated to the rest of the PR, or to other items, gets a separate commit. This is common for file and conversation comments. That way the reviewer can verify each fix on its own.
- **Related items share a commit.** If items are related or share a blast radius, fold them into the same commit.
- Write commit messages that say what changed and why.
- **Push** when you're done, using the repo's identity rules from section 0. Every SHA you cite must exist on the remote.

## 5. Reply, and never close anything

After pushing, reply to every item.

**Review thread** (line or file comment). Reply in the thread. `COMMENT_ID` is the `databaseId` of the thread's *first* comment:

```bash
gh api -X POST "repos/{owner}/{repo}/pulls/$PR/comments/$COMMENT_ID/replies" -f body="..."
```

**Conversation comment.** Post a new PR comment whose first line links the comment you're answering:

```bash
gh pr comment $PR --body "Re: <the comment's url>

..."
```

**What each reply must contain.**

- **Fixed**: what you changed, any other occurrences you also fixed, a full commit URL, and the files touched. If the fix spans several commits, link a compare range instead. "Done" or "Fixed" on its own is not a reply.
- **Disagreed**: why, concretely, and what you'd need to hear to change your mind.
- **Blocked**: three things.
  1. What you tried and what happened.
  2. What specifically is blocking you.
  3. A direct question with options, for example: (a) …, (b) …, (c) leave as is. Which do you prefer?

  Escalate as Blocked rather than pushing through in any of these cases:
  - two attempts at the same fix have failed;
  - the fix needs a decision that isn't yours: a new dependency, a public API break, a schema change, or a security tradeoff;
  - two items contradict each other;
  - you can't reproduce the problem;
  - tests already fail on the base branch;
  - the fix is much bigger than the feedback implies.

**Never close anything.** Do not:

- resolve a thread;
- hide (including "hide as resolved") or edit the reviewer's comments;
- submit a PR review (approve, request changes) or merge.

Resolving is the reviewer's signal that they verified your work, and it's the only signal they have.

## 6. Done means

- Every item from step 1 has your reply as its latest entry.
- Every Fixed reply cites a pushed commit and the files it touched.
- Nothing was resolved or hidden by you.
- `git status` is clean and there are no unpushed commits.
- The full test suite passes, or the failure is reported as Blocked.
- Re-running step 1 shows no open item left without your reply.

Your final chat message is a one-line summary. For example:

> 6 items: 4 fixed, 1 pushed back (foo.py:88), 1 blocked on the cache question. Tests pass.

The detail belongs in the replies, not the chat.
