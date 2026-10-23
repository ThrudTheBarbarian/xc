# Security

## Reporting a problem

Please report security problems **privately**, not in a public issue:

- through GitHub's **Report a vulnerability** button on the repository's
  Security tab, or
- by email to xc@oobergeek.net.

Say what the problem is, how to reproduce it, and which version and platform
you found it on. We will acknowledge the report within a week, keep you told
of progress, and credit you in the release notes unless you would rather not
be named.

## What counts

Anything where xcc, its runtime or UXKit lets someone do what they should not
be able to, for example:

- code signing, bundle signatures, plugin verification or key handling that
  accepts something it should reject;
- `xcd` accepting work or data from a machine that is not in its pool;
- a compiled program behaving unsafely because of the compiler or runtime
  (not because of a bug in the program itself);
- the TLS library.

## Supported versions

Fixes go into the next release. Older releases are not patched.
