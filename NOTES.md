# Java → Python gotcha journal
Log every Python surprise here. This becomes (a) your "what I learned" interview
answer and (b) evidence of independent debugging for the AI-disclosure section.

Format: date | what bit me | Java habit that caused it | Python fix

## Known traps to watch for (pre-seeded):
- Mutable default arguments: `def f(x, acc=[])` shares ONE list across calls.
  Use `acc=None` + `if acc is None: acc = []`.
- Truthiness: empty list/dict/str are falsy. `if response["items"]:` skips
  empty lists - sometimes you want `if "items" in response:` instead.
- Timezones: `datetime.now()` is naive. Always `datetime.now(timezone.utc)`.
- Integer division: `/` always returns float; `//` is floor division.
- boto3 clients are not thread-safe to CREATE concurrently, but are safe to
  USE; create once at module level (also faster on warm invocations).

## My entries:
- 
