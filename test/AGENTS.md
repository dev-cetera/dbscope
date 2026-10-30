# Writing tests

Rules for tests. The rules in the root `AGENTS.md` apply too.

- **A test must be able to fail.** Before you trust a new test, break the code it covers and watch it go red. A test that passes against broken code is worse than no test.
- **Test behaviour, not the implementation.** Assert on what a user or caller sees, not on private calls or how many times a mock was hit.
- **Never weaken a test to make it pass.** Don't loosen an expectation, widen a tolerance, delete an assert or add a skip. If the test is wrong, say why in your report. If the code is wrong, fix the code.
- **A bug fix comes with a test** that fails on the old behaviour, when the bug can be reproduced.
- **No sleeps to dodge timing.** Wait for the condition, or use a fake clock.
- **Run one file first,** then the suite once that file passes.
- **One test, one reason to fail.** The test name says what should happen, for example `rejects an expired token`.

A flaky test is a bug. Put it in `BUGS.md` with how often it fails and the error you saw.
