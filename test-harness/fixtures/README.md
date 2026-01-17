# Test Fixtures for Neovim Plugin Diff Highlighting

This directory contains test fixtures for verifying that the neovim plugin correctly displays diff highlighting for code changes.

## Files

### mesh_grid.rs
The original Rust source file before any changes. This is the baseline file that the diff will be applied to.

### mesh_grid.patch
A unified diff patch file that contains all the changes to be applied to mesh_grid.rs. This patch includes:

1. **Import addition**: Adding `use sprs_ldl::LdlNumeric;` at line 13
2. **Function call update**: Replacing the commented-out `calculate_trivial_connection` call with a new implementation that:
   - Finds the north pole vertex
   - Calls `calculate_trivial_connection` with new parameters including the north pole singularity
3. **Function signature change**: `calculate_trivial_connection` now takes direct references to adjacency structures instead of a `MeshGrid` reference
4. **Implementation completion**: The function now has a full implementation including:
   - LDL decomposition for solving linear systems
   - Matrix operations for computing the trivial connection
   - Helper functions for finding the north pole and removing vertices from the system
5. **New helper functions**:
   - `find_north_pole_vertex`: Finds the vertex with maximum Y coordinate
   - `remove_vertex_from_system`: Removes a vertex from a linear system
   - `fix_north_pole_edges`: Sets edges connected to the north pole to zero
6. **Test modifications**: Updated test cases to use `MeshGridInner::new` instead of `MeshGrid::new`

### README.md
This documentation file.

## Integration Tests

The actual plugin tests are located in `/nvim/tests/diff_integration_spec.lua`. These tests verify the `codeforge.diff` module functions:

- **`parse_hunk_header`**: Parses all 7 hunk headers from mesh_grid.patch
- **`parse_diff_changes`**: Parses changes from real hunks (hunks 1, 2, 3)
- **`apply_hunk`**: Applies hunks to the original file and verifies the results
- **`get_added_lines`**: Extracts added lines from hunks
- **`get_removed_lines`**: Extracts removed lines from hunks
- **`compute_diff`**: Computes diff between original and modified files

## Running Tests

To run the integration tests:

```bash
nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
```

Or run just the diff integration tests:

```bash
nvim --headless -c "PlenaryBustedFile tests/diff_integration_spec.lua {minimal_init = 'tests/minimal_init.lua'}"
```

## Expected Hunks

The patch contains 7 hunks:

1. **Hunk 1** (lines 10-10 → 10-10): Import addition
   - 1 addition: `use sprs_ldl::LdlNumeric;`

2. **Hunk 2** (lines 604-611 → 605-616): Function call update
   - 2 deletions: Commented code and empty vec
   - 8 additions: New function call with north pole

3. **Hunk 3** (lines 646-676 → 653-744): Function signature and implementation
   - 31 deletions: Old function signature and incomplete implementation
   - 92 additions: New function signature and complete implementation

4. **Hunk 4** (lines 770-772 → 842-894): New helper functions
   - 53 additions: Three new helper functions

5. **Hunk 5** (lines 778-784 → 900-906): Test modification 1
   - 2 modifications: Grid initialization and TAU constant

6. **Hunk 6** (lines 798-804 → 920-926): Test modification 2
   - 1 modification: Grid initialization

7. **Hunk 7** (lines 820-826 → 942-948): Test modification 3
   - 1 modification: Grid initialization

## Notes

- The patch file uses unified diff format with context lines
- Line numbers in the patch are relative to the original file
- The test fixtures are designed to be comprehensive and cover edge cases
- All changes must be displayed exactly as specified in the patch file
- The integration tests verify the plugin's diff parsing and application logic, not the Rust code correctness
