# Zig Style

## 1. Core Rules

### 1.1 Readability first

- prefer clear code over clever code
- keep functions small
- make control flow obvious
- shape APIs for Zig, not C++

### 1.2 Comments are contracts

- keep doc comments accurate
- state limitations explicitly
- remove stale comments immediately

## 2. Error Handling

### 2.1 No silent swallowing

- every `catch` must be intentional
- prefer exhaustive `switch`
- do not erase useful errors

### 2.2 OutOfMemory must propagate

- never hide `error.OutOfMemory`
- if a return type cannot express OOM, document the limitation

### 2.3 C interop error checking

- C calls returning `-1` require reading real `errno`
- do not treat return values as negated errno

### 2.4 No `catch unreachable` for heap allocation

- allocation can fail
- use `try`, `catch`, or an explicit OOM path

## 3. Resource Safety

### 3.1 Immediate `defer` / `errdefer`

- put cleanup on the next line after acquisition
- use `errdefer` for multi-step initialization

### 3.2 File and OS resources

- every descriptor gets `defer close` or `errdefer close`
- use `CLOEXEC` where applicable
- on partial setup failure, unwind all prior resources with `errdefer`

## 4. Input Validation

### 4.1 Trust boundaries

- treat network, disk, config, C API, and wire data as untrusted
- validate before use

### 4.2 No silent truncation

- if data does not fit, return an error
- use checked casts unless truncation is intentional

### 4.3 Binary protocol parsing

- reject unknown or reserved values
- bounds-check offsets and pointers
- cap recursion or indirection depth
- validate every field independently
- for length-delimited records, verify exact bytes consumed
- cap allocations derived from untrusted counts

### 4.4 Path and text inputs

- reject traversal components, null bytes, and unsafe control characters

## 5. Structure

### 5.1 Size

- target functions: <= 120 lines
- hard review trigger: 150 lines
- target files: <= 1500 lines excluding tests
- review trigger: 2000 lines

### 5.2 Layout

Use this order:

1. file comment
2. imports
3. public types
4. private types
5. public functions
6. private functions
7. tests

### 5.3 Readability rules

- parenthesize bitwise expressions mixed with comparisons
- remove dead code quickly
- prefer one canonical implementation path

### 5.4 Zig API design

- prefer typed composition over opaque internal callbacks
- prefer owned data or stable snapshots over fragile borrows
- keep exports curated

## 6. Naming

- functions and methods: `camelCase`
- types: `PascalCase`
- locals: `snake_case`
- use clear import names, not abbreviations

## 7. C Interop

### 7.1 Strings

- C strings must be sentinel-terminated
- use standard helpers, not manual `\0` assembly

### 7.2 Integer conversions

- use checked conversions at C boundaries
- use `@intCast` only when bounds are known

### 7.3 External strings

- scan strings crossing C boundaries for nulls and unsafe control bytes

## 8. Concurrency

### 8.1 Mutation model

- prefer one clear mutator where practical

### 8.2 Lock discipline

- document ordering when multiple locks exist
- minimize work under lock
- do not keep pointers across lock release if backing storage can move

## 9. Workflow

### 9.1 Bug-fix loop

1. find a small set of issues
2. fix them
3. run relevant tests
4. repeat

### 9.2 Commit discipline

- every commit should pass the relevant checks for the changed area
- commit messages should explain what changed and why

### 9.3 New code expectations

- add happy-path tests
- add error-path tests
- add boundary tests
- add parser/adversarial tests where applicable

### 9.4 Mandatory audit after writing

- audit new code against this file and `CODING_STANDARDS.md`
- fix issues as you find them
- add regression tests for each real bug
