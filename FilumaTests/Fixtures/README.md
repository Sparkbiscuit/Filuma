# Legacy SwiftData fixture

`legacy-filuma.store` was created by the unchanged model schema at commit
`52a1c893b039db5271db6cd6811e4525c0dc48d6` on iOS Simulator 26.5.
It contains only authored test data: a task with a first step, 25% progress and
one locked reservation; a recurring template; settings with a 120-minute
saved deadline buffer. It contains no personal user records.

The SQLite WAL was checkpointed before copying the fixture. The migration
regression copies it into a temporary directory and opens it with the current
`SharedStore.schema`, checks the relationships and saved buffer, and saves a
new per-task override. The original fixture is never modified by tests.
