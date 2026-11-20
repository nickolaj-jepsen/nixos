# Docs and READMEs

Who opens this page, and what brings them here? A contributor who knows the framework may need one local convention. Someone deciding whether to install a plugin needs to see what it does and whether it works in their setup. Both can skip the history of the implementation.

Choose a shape that fits the question. A short README can answer it in a paragraph.

- **Tutorial.** Walk a newcomer through one useful outcome. Let them see it working early.
- **How-to.** Start with the task. Give the steps in the order the reader takes them and show how they can tell it worked.
- **Reference.** Organize around the names readers look up. If the CLI help or an existing reference already answers the question, point there where the reader needs it.
- **Explanation.** Show how the parts relate. A small map can give the reader their bearings, then one worked example makes the relationship concrete.

For example, a “How a run works” page can follow a script that pushes a change, waits overnight for CI and resumes using the recorded push. Once the reader understands how the wait works, stop. What happens if a process crashes _during_ the push belongs with recovery.

Use headings a reader would look for. Keep connected reasoning in paragraphs. A list is useful when readers can use its items separately. If a paragraph has no job left after you remove the obvious details, delete it.
