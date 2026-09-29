# Zig Consistent Hash Ring
A library which implements a consistent hash ring in Zig. Supports both static and stateful hashers via generic construction, as well as arbitrary hash types. It is assumed that the hash type is naively comparable.

## Todo
- Add thread safe functions
- Implement improvements based on Google research paper e.g. partitions
- Add more flexibilty to the allocation strategies
- Allow generic key types
- Allow any hash type that implements fn eql(lhs, rhs) bool
- Add visualization program
- Provide additional convenience definitions e.g. for with static hasher vs stateful hasher
