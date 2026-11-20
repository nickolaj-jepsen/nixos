# Docs and READMEs

Who opens this page, and what brings them here? A contributor who knows the framework may need one local convention. Someone deciding whether to install a plugin needs to see what it does and whether it works in their setup. Both can skip the history of the implementation.

Choose a shape that fits the question. A short README can answer it in a paragraph.

- **Tutorial.** Walk a newcomer through one useful outcome. Let them see it working early.
- **How-to.** Start with the task. Give the steps in the order the reader takes them and show how they can tell it worked.
- **Reference.** Organize around the names readers look up. If the CLI help or an existing reference already answers the question, point there where the reader needs it.
- **Explanation.** Show how the parts relate. A small map can give the reader their bearings, then one worked example makes the relationship concrete.

For example, a “How a run works” page can follow a script that pushes a change, waits overnight for CI and resumes using the recorded push. Once the reader understands how the wait works, stop. What happens if a process crashes _during_ the push belongs with recovery.

Use headings a reader would look for. Keep connected reasoning in paragraphs. A list is useful when readers can use its items separately. If a paragraph has no job left after you remove the obvious details, delete it.

## Organizing a repository

Start at the entry point a reader actually has: the repository landing page, an installed package, the CLI, or the team's runbook. Trace a real question from there. Reuse an existing page when that lets the reader finish. Split at a change in reader or task: an operator recovering a failed deployment needs a different path from someone deciding whether to install.

- A prototype may need only a README with the purpose, one working example and the limits someone trying it will hit. For an agent-built project, the most valuable addition may be a short map and one run through it.
- A shared project needs the conventions and checks that a new contributor would otherwise learn by breaking something. Skip framework basics and incidental per-feature history.
- An installed tool or library can have readers without the source tree. Keep accessible lookup material for supported behavior, defaults, errors, prerequisites and upgrades where those affect its users. Verify release promises and actual consumers before assuming compatibility.
- A diagram earns its space when it explains a relationship; an example earns its space when someone can use it. A table helps when a reader chooses between entries. A page owes the reader no fixed set of sections.

During a refresh, use the approved sample passage to guide the remaining edits. Build navigation around the agreed reader tasks. Remove empty branches. Check incoming links, packaged docs, search terms and any generated indexes. Use the original reader questions to check the result. Leave durable project choices to the owner's designated file and describe observable behavior where people need it.

[Diátaxis on growing structure from reader needs](https://diataxis.fr/how-to-use-diataxis/) · [Google on minimum viable documentation](https://google.github.io/styleguide/docguide/best_practices.html)
