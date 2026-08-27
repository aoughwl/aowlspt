import aowl/src/aowlspt/json

## Test suite for json.nim child() boundary fix
## Bug: dotted paths failed on array-element refs when skipValue advanced past j.last
## Fix: changed loop from `while i <= j.last` to `while i < s.len`
##
## Key safety invariant: the check `if s[i] == '}'` at loop top ensures
## we stop at the closing brace of the current object, preventing false
## positives where we'd scan into the next array element.

# Test 1: Original bug - large nested value before target key
proc test_nested_value_before_key() =
  let jsonData = """[{"template":{"Position":{"x":1.0}},"prob":0.5}]"""
  let root = whole(jsonData)
  let elem = at(root, 0)
  
  # Both forms should work
  let nested = field(field(field(elem, "template"), "Position"), "x")
  let dotted = field(elem, "template.Position.x")
  
  assert nested.found, "nested form should find"
  assert dotted.found, "dotted form should find"
  assert nested.asText() == dotted.asText(), "should match"
  echo "Test 1 PASS: Large nested value doesn't block later keys"

# Test 2: Critical false positive check - elem[0] missing key found in elem[1]
proc test_no_false_positive_simple() =
  let jsonData = """[{"name":"elem0"},{"Position":42}]"""
  let root = whole(jsonData)
  let elem0 = at(root, 0)
  
  let pos = field(elem0, "Position")
  assert not pos.found, "elem0 must NOT find Position from elem1"
  echo "Test 2 PASS: No false positive with missing key"

# Test 3: False positive check with dotted path
proc test_no_false_positive_dotted() =
  let jsonData = """[{"x":{"y":1}},{"x":{"z":42}}]"""
  let root = whole(jsonData)
  let elem0 = at(root, 0)
  
  let z = field(elem0, "x.z")
  assert not z.found, "elem0 must NOT find x.z from elem1"
  echo "Test 3 PASS: Dotted path doesn't scan into elem1"

# Test 4: Reverse order - missing key earlier in element
proc test_missing_early_key() =
  let jsonData = """[{"a":{"target":1},"b":2},{"a":{"target":999}}]"""
  let root = whole(jsonData)
  let elem0 = at(root, 0)
  let elem1 = at(root, 1)
  
  let from0 = field(elem0, "a.target")
  let from1 = field(elem1, "a.target")
  
  assert from0.found and from0.asInt() == 1, "elem0 should find 1"
  assert from1.found and from1.asInt() == 999, "elem1 should find 999"
  echo "Test 4 PASS: Correctly distinguishes between elements"

# Test 5: Multiple array elements - the 552-row scenario
proc test_multiple_elements() =
  let jsonData = """[
    {"template":{"Position":{"x":1.0}},"prob":0.1},
    {"template":{"Position":{"x":2.0}},"prob":0.2},
    {"template":{"Position":{"x":3.0}},"prob":0.3}
  ]"""
  let root = whole(jsonData)
  
  for i in 0..2:
    let elem = at(root, i)
    let pos = field(elem, "template.Position.x")
    assert pos.found, "should find in element " & $i
    assert pos.asFloat() == float(i + 1), "value mismatch in element " & $i
  
  echo "Test 5 PASS: 552-row scenario works (3 tested)"

# Test 6: Missing key genuinely absent
proc test_genuinely_missing() =
  let jsonData = """[{"a":1,"b":2}]"""
  let root = whole(jsonData)
  let elem = at(root, 0)
  
  let missing = field(elem, "nonexistent")
  assert not missing.found, "nonexistent key should return notFound"
  echo "Test 6 PASS: Missing keys still return notFound"

# Test 7: Nested dotted path with element boundary
proc test_deep_dotted_at_boundary() =
  let jsonData = """[{"a":{"b":{"c":{"d":1}}}}]"""
  let root = whole(jsonData)
  let elem = at(root, 0)
  
  let deep = field(elem, "a.b.c.d")
  assert deep.found, "deep dotted path should work"
  assert deep.asInt() == 1, "deep value should be 1"
  echo "Test 7 PASS: Deep paths work correctly"

# Run all tests
test_nested_value_before_key()
test_no_false_positive_simple()
test_no_false_positive_dotted()
test_missing_early_key()
test_multiple_elements()
test_genuinely_missing()
test_deep_dotted_at_boundary()

echo "\nAll json boundary tests PASSED!"
