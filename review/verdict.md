
## Machine-readable verdict

After the coverage note, add one line and nothing else:

`REVIEW-VERDICT: BLOCK` when the report contains at least one P0 or P1 finding.

`REVIEW-VERDICT: PASS` otherwise, including when every finding is P2 or P3 and
when the report says "No actionable P0–P3 findings identified."

Write the line without a code fence, without backticks, and without trailing
text. The last occurrence decides the outcome, so do not repeat it.
