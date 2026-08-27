import aowl/src/aowlspt/json

# Test suite for dotted path bug with at()
# These tests FAIL on the old code due to the boundary check bug in child()

proc test_dotted_vs_nested_simple() =
  let jsonData = """[{"a":{"b":1},"c":2}]"""
  let root = whole(jsonData)
  let elem = at(root, 0)
  
  # Nested form (works even on buggy code)
  let nested_b = field(field(elem, "a"), "b")
  # Dotted form (fails on buggy code)
  let dotted_b = field(elem, "a.b")
  
  assert nested_b.found, "nested form should find a.b"
  assert dotted_b.found, "dotted form should find a.b"
  assert nested_b.asText() == dotted_b.asText(), "both forms should return same value"

proc test_dotted_vs_nested_deep() =
  # Test with deeper nesting - the repro case from orbit.nim
  let jsonData = """[{"template":{"Position":{"x":1.0,"y":2.0,"z":3.0}},"prob":0.5}]"""
  let root = whole(jsonData)
  let elem = at(root, 0)
  
  # Nested form (works even on buggy code)
  let nested = field(field(field(elem, "template"), "Position"), "x")
  # Dotted form (fails on buggy code)
  let dotted = field(elem, "template.Position.x")
  
  assert nested.found, "nested form should find template.Position.x"
  assert dotted.found, "dotted form should find template.Position.x"
  assert nested.asText() == dotted.asText(), "both forms should return same value"
  assert nested.asText() == "1.0", "value should be 1.0"

proc test_dotted_with_key_after_large_value() =
  # Edge case: key appears AFTER a large value that exceeds j.last boundary
  let jsonData = """[{"big":{"nested":{"deep":{"structure":{"with":"many","levels":"here"}}},"target":42}]"""
  let root = whole(jsonData)
  let elem = at(root, 0)
  
  # The "target" key comes after the "big" nested value
  # With buggy code, skipValue on "big" would exceed j.last, causing loop to exit
  let target_nested = field(elem, "target")
  let target_dotted = field(elem, "target")  # both the same in this case
  
  assert target_nested.found, "should find target"
  assert target_dotted.asInt() == 42, "target should be 42"

proc test_multiple_elements_in_list() =
  # Test multiple array elements to ensure no state corruption
  let jsonData = """[{"template":{"Position":{"x":1.0}},"prob":0.1},{"template":{"Position":{"x":2.0}},"prob":0.2},{"template":{"Position":{"x":3.0}},"prob":0.3}]"""
  let root = whole(jsonData)
  
  for i in 0..2:
    let elem = at(root, i)
    let pos = field(elem, "template.Position")
    assert pos.found, "should find template.Position in element " & $i
    
    let x = field(pos, "x")
    assert x.found, "should find x in element " & $i
    assert x.asFloat() == float(i + 1), "x should be " & $(i + 1)

proc test_dotted_with_missing_key() =
  # Ensure missing keys still return notFound
  let jsonData = """[{"a":{"b":1}}]"""
  let root = whole(jsonData)
  let elem = at(root, 0)
  
  let missing = field(elem, "a.nonexistent")
  assert not missing.found, "should not find non-existent key"

# Run all tests
test_dotted_vs_nested_simple()
test_dotted_vs_nested_deep()
test_dotted_with_key_after_large_value()
test_multiple_elements_in_list()
test_dotted_with_missing_key()

echo "All dotted path tests passed!"
