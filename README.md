# overwatch.nvim

Review agent-written PRs in Neovim without panels. You look at what changed, comment on any line you like as a PR comment (whether or not the PR touched it), and hand the comments to whatever agent you use.

Requires [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim), the [`gh`](https://cli.github.com) CLI, and Neovim 0.11 or later.

## Install (lazy.nvim)

```lua
{
  'cyalen/overwatch.nvim',
  dependencies = { 'lewis6991/gitsigns.nvim' },
  cmd = 'Overwatch',
  opts = {},
  keys = {
    { '<leader>rr', function() require('overwatch').toggle() end, desc = '[R]eview start/stop' },
    { '<leader>rf', function() require('overwatch').files() end, desc = '[R]eview changed [F]iles' },
    { '<leader>rv', function() require('overwatch').seen() end, desc = '[R]eview: seen, next file' },
    { '<leader>rd', function() require('overwatch').diff() end, desc = '[R]eview side-by-side [D]iff' },
    { '<leader>rc', function() require('overwatch').comment() end, mode = { 'n', 'x' }, desc = '[R]eview [C]omment/reply' },
    { '<leader>rx', function() require('overwatch').resolve() end, desc = '[R]eview resolve thread' },
    { '<leader>rs', function() require('overwatch').verdict() end, desc = '[R]eview [S]ubmit verdict' },
    { '<leader>ra', function() require('overwatch').handoff() end, desc = '[R]eview copy [A]gent prompt' },
    { ']q', function() require('overwatch').next() end, desc = 'Next change (review-aware :cnext)' },
    { '[q', function() require('overwatch').prev() end, desc = 'Previous change (review-aware :cprev)' },
    { ']r', function() require('overwatch').next_comment() end, desc = 'Next PR comment in file' },
    { '[r', function() require('overwatch').prev_comment() end, desc = 'Previous PR comment in file' },
  },
}
```

## Using it

1. **Start.** `<leader>rr` reviews the PR for the branch you're on. If the branch has no PR, it lets you pick one. Each PR in the picker is marked with a yellow `●` when it needs your review (no decision yet, or commits since your last review), a green `✓` when approved, or a red `✗` when changes were requested. The colours come from your theme when telescope is installed. Your current checkout stays as it is:
   - If the PR's branch is already checked out somewhere (for example the agent's worktree), the review opens there in a new tab, with `:tcd` pointing that tab at the worktree.
   - Otherwise, the PR is checked out into a fresh worktree at `.overwatch/pr-N` in the main checkout. Remove it with `git worktree remove` when you're done.

   Use `:Overwatch pr 306` to pick a specific PR, or `:Overwatch <rev>` to review against any revision. `<leader>rr` again ends the review and closes the tab it opened.

   gitsigns diffs every buffer against the merge-base with the PR's base branch. `]c`/`[c` move between changes within a file. `]q`/`[q` move to the next or previous change after your cursor, carrying on into the next file.

2. **Only what's new since your last review.** "Your last review" is your last submitted review on GitHub (approve, request changes, or a comment with a body), or the files you ticked here, whichever is newer. Say you reviewed commits A–C, which touched `x.sh` and `y.sh`. The agent then pushes commit D, which touches only `x.sh`. The next review shows just `x.sh`, diffed against what you saw, so only D's lines appear. Ticks are saved as you make them, and this survives rebases and force-pushes. To always open on the whole PR, set `opts = { since_last_review = false }`.

   `<leader>rf` opens the file tree, a narrow directory tree with `+/-` counts and a `●` count of open PR threads. Each file shows:
   - `○` (gray): not reviewed;
   - `✓` (green): reviewed;
   - `◐` (yellow): reviewed, but changed since.

   In the tree:
   - `<CR>` opens a file or folds a directory;
   - `x` ticks (or unticks) a file, or everything in a directory;
   - `a` switches between "since last review" and the whole PR;
   - `R` refreshes;
   - `q` closes.

   Outside the tree, `<leader>rv` means "done with this file": it ticks the file and opens the next unreviewed one.

3. **Side by side.** `<leader>rd` shows the full file next to its review base. It stays on as you move between files, until you press it again.

   **Goto during a review.** Wrap your LSP goto pickers with `in_pane`. During a review, their results then open in one reusable pane to the right, as a normal editable buffer, and the file you're reviewing stays where it is. Outside a review the pickers behave as usual. With telescope:

   ```lua
   local pane = function(picker) return function() require('overwatch').in_pane(picker) end end
   vim.keymap.set('n', 'grd', pane(require('telescope.builtin').lsp_definitions))
   vim.keymap.set('n', 'grr', pane(require('telescope.builtin').lsp_references))
   ```

   It works with any picker that takes `{ bufnr, winnr }` for where to look up the symbol, and opens its result in the current window.

4. **Comment on anything.** `<leader>rc` comments on the line or selection, and the comment goes straight to the PR.
   - **Lines the PR changed:** an ordinary line comment.
   - **Other lines in a file the PR touches:** a comment on the file. It carries a link to the exact lines at the PR head and the code you selected, followed by your text.
   - **Files the PR doesn't touch:** the same comment, posted to the PR's main conversation. GitHub doesn't allow review comments on those files.
   - **A line that already has a thread:** shows the thread, and you reply to it.
   - **A whole file:** press `<leader>rc` on the file in the file tree. The comment sits at the top of the file, like any thread. On the `💬 PR conversation` row, `<leader>rc` starts a new comment on the PR itself.

   Inside the float, `<CR>` in normal mode sends and `q` cancels.

5. **Whose turn.** A `●` in the sign column marks each open thread, on the lines it's about (outdated threads sit at their original line). `]r`/`[r` cycle through them in a file. A thread is purple while you had the last word, and yellow once the agent (or anyone else) replies. The tree's `●` counts turn yellow the same way. Verify the fix, then `<leader>rx` resolves the thread. The agent never resolves anything itself.

6. **PR conversation.** Comments on the PR itself, rather than on code, live in the file tree as a `💬 PR conversation ●N` row, which is yellow when someone else spoke last in any discussion. GitHub's conversation is flat, so overwatch rebuilds the discussions:
   - a reply that starts with `Re: <link>` joins the comment it links to (replies from nvim and from agents do this);
   - so does one made with GitHub's "Quote reply".

   N counts discussions, not comments. `<CR>` opens the conversation in the main window. There, each discussion is one entry, with its replies indented under it. `]r`/`[r` move between discussions. `<leader>rc` replies into the one under the cursor. `<leader>rx` hides the whole discussion on GitHub as resolved. If a review starts with no code to look at but comments waiting on you, the conversation opens by itself. Files with a thread waiting on you show in the tree even when their code hasn't changed.

7. **Hand off.** `<leader>ra` copies the agent prompt. Paste it into any agent.

8. **Verdict.** `<leader>rs` approves, requests changes, or leaves a review comment.

Comments posted to the main conversation (point 4, for files the PR doesn't touch) appear in the PR conversation (point 6), not inline in the file.

## Bring your own agent

Every agent gets the same one-line prompt:

> Address the review feedback for this branch by following .overwatch/PROTOCOL.md.

[`PROTOCOL.md`](PROTOCOL.md) is copied into `.overwatch/` in each repo, so sandboxed agents can read it. It tells the agent to:

- read every open PR comment before changing anything;
- answer each one as Fixed, Disagreed or Blocked;
- put unrelated fixes in separate commits, then push;
- reply on the PR;
- never resolve anything.

Your repo's own agent instructions (AGENTS.md, CLAUDE.md, skills) take precedence. Use them for bot identities and other house rules.

To save the prompt as a command:

- **Claude Code**: `ln -s "$PWD/adapters/claude-code/overwatch.md" ~/.claude/commands/overwatch.md`. Then run `/overwatch`.
- **Anything else**: put the prompt line above wherever your agent keeps saved prompts.

## Test

```sh
nvim -l tests/comment_test.lua
```
