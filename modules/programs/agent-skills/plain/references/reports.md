# Research reports and findings

The reader may read only the top. Everything below it is for checking.

- The first sentence answers the question, including "no" or "the data doesn't show that".
- Then the findings, most consequential first. Each one: the claim, how sure you are, the evidence in a line, and what you'd do about it.
- Separate what you saw from what you infer. Say what you didn't read or couldn't check.
- Counts, not adjectives: "7 of 20 runs" rather than "frequently". One case is an anecdote; say so.
- Use the same likelihood words throughout: unlikely, roughly even, likely, very likely. Don't stack them ("probably likely"), and don't explain the scale.
- Respect a length the reader asked for. A short report is the summary and the findings that matter. Leave out what you checked and found fine, unless the reader needs it to trust the rest.
- A header per finding when there are several, so the reader can jump to one. A table when findings share columns.
- A recommendation is one line the reader can say yes to.

## Example

```text
After a thorough investigation across multiple sources, several interesting
patterns emerged regarding how the skill is used. Notably, users frequently
seem to interrupt it, which suggests there may be room for improvement in how
it is triggered.

→
The skill fires when it shouldn't.

- 5 of the 14 runs the model started were interrupted within two turns.
- None of the 6 runs you started were.
- Every interrupted run was on a design doc.

I'd drop design docs from its description. I read all 20 runs.
```

The first version says something happened. The second says what, how often, compared to what, and what to change.
