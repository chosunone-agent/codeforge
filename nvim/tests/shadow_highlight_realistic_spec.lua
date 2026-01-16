-- Test with realistic hunks based on the actual mesh_grid.rs file
-- Run with: nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"

-- Mock store module for tests
local mock_store = {
  cache_original_content = function() end,
  get_original_content = function() return nil end,
  get_suggestion_by_hunk_id = function(hunk_id)
    -- Return the mock suggestion with realistic hunks
    return mock_suggestion
  end,
}
package.loaded["codeforge.store"] = mock_store

local shadow = require("codeforge.ui.shadow")
local diff_utils = require("codeforge.diff")

-- Create a realistic mock suggestion with hunks that might appear in mesh_grid.rs
-- These are smaller, more realistic hunks that add a few lines each
local mock_suggestion = {
  id = "test-suggestion",
  hunks = {
    {
      id = "test-suggestion:mesh_grid.rs:0",
      file = "mesh_grid.rs",
      diff = "@@ -10,3 +10,6 @@\n    pub center: Vec3,\n+    pub normal: Vec3,\n    pub vertices: [u32; 3],\n}",
    },
    {
      id = "test-suggestion:mesh_grid.rs:1",
      file = "mesh_grid.rs",
      diff = "@@ -50,2 +52,5 @@\n/// Vertex -> Cell adjacency marker\n+/// Vertex -> Edge adjacency marker\n/// Edge -> Vertex adjacency marker",
    },
    {
      id = "test-suggestion:mesh_grid.rs:2",
      file = "mesh_grid.rs",
      diff = "@@ -100,3 +104,6 @@\n    pub fn len(&self) -> usize {\n        self.offsets.len().saturating_sub(1)\n    }\n+    \n+    #[must_use]\n+    pub fn is_empty(&self) -> bool {\n        self.len() == 0\n    }",
    },
    {
      id = "test-suggestion:mesh_grid.rs:3",
      file = "mesh_grid.rs",
      diff = "@@ -150,2 +156,5 @@\n        &self.indices\n    }\n+    \n+    pub fn get(&self, idx: usize) -> impl Iterator<Item = usize> + '_ {\n        let start = self.offsets[idx] as usize;",
    },
    {
      id = "test-suggestion:mesh_grid.rs:4",
      file = "mesh_grid.rs",
      diff = "@@ -200,3 +208,6 @@\n        let mut edge_map: HashMap<(u32, u32), u32> = HashMap::new();\n        let mut next_edge_idx = 0u32;\n+        \n        for cell_idx in 0..num_cells {",
    },
    {
      id = "test-suggestion:mesh_grid.rs:5",
      file = "mesh_grid.rs",
      diff = "@@ -250,2 +260,5 @@\n                let canonical = (v0.min(v1), v0.max(v1));\n\n                edge_map.entry(canonical).or_insert_with(|| {",
    },
    {
      id = "test-suggestion:mesh_grid.rs:6",
      file = "mesh_grid.rs",
      diff = "@@ -300,3 +312,6 @@\n        let mut offsets = Vec::with_capacity(num_cells + 1);\n        let mut indices = Vec::with_capacity(num_cells * 3);\n+        \n+        for cell_idx in 0..num_cells {",
    },
    {
      id = "test-suggestion:mesh_grid.rs:7",
      file = "mesh_grid.rs",
      diff = "@@ -350,2 +364,5 @@\n            let canonical = (v0.min(v1), v0.max(v1));\n                let is_primary = v0 < v1;\n\n                let entry = edge_map.entry(canonical).or_insert_with(|| {",
    },
    {
      id = "test-suggestion:mesh_grid.rs:8",
      file = "mesh_grid.rs",
      diff = "@@ -400,3 +416,6 @@\n        let num_edges = edge_map.len();\n\n        let mut offsets = Vec::with_capacity(num_edges + 1);\n+        \n+        for (edge_idx, cells, _) in edge_map.values() {",
    },
    {
      id = "test-suggestion:mesh_grid.rs:9",
      file = "mesh_grid.rs",
      diff = "@@ -450,2 +468,5 @@\n        let num_edges = edge_set.len();\n\n        let mut offsets = Vec::with_capacity(num_edges + 1);\n        let mut indices = vec![0u32; num_edges * 2];",
    },
    {
      id = "test-suggestion:mesh_grid.rs:10",
      file = "mesh_grid.rs",
      diff = "@@ -500,3 +520,6 @@\n        let mut offsets = Vec::with_capacity(num_vertices + 1);\n        let mut running = 0u32;\n        for &count in &counts {\n            offsets.push(running);\n+            running += count;\n+        }\n        offsets.push(running);",
    },
    {
      id = "test-suggestion:mesh_grid.rs:11",
      file = "mesh_grid.rs",
      diff = "@@ -550,2 +572,5 @@\n        let mut write_pos = offsets[..num_vertices].to_vec();\n        let mut indices = vec![0u32; running as usize;\n\n        for cell_idx in 0..num_cells {",
    },
    {
      id = "test-suggestion:mesh_grid.rs:12",
      file = "mesh_grid.rs",
      diff = "@@ -600,3 +624,6 @@\n        let mut vertex_edges = vec![Vec::new(); num_vertices];\n        for edge_idx in 0..num_edges {\n            let verts = edge_vertex_adjacency.get(edge_idx).collect::<Vec<_>>();\n+            let v_lower = verts[0];\n+            let v_higher = verts[1];\n+            vertex_edges[v_lower].push(edge_idx as u32);\n+            vertex_edges[v_higher].push(edge_idx as u32);",
    },
    {
      id = "test-suggestion:mesh_grid.rs:13",
      file = "mesh_grid.rs",
      diff = "@@ -650,2 +676,5 @@\n            let vertex_pos: Vec3 = points[vertex_idx].into();\n            let vertex_normal = vertex_pos.normalize();\n\n            let is_pole = vertex_normal.x.abs() < 1e-6",
    },
    {
      id = "test-suggestion:mesh_grid.rs:14",
      file = "mesh_grid.rs",
      diff = "@@ -700,3 +728,6 @@\n            let tangent_x = vertex_normal.cross(up).normalize();\n            let tangent_y = tangent_x.cross(vertex_normal).normalize();\n\n            let mut edge_angles = edges\n+                .iter()\n+                .map(|&edge_idx| {",
    },
    {
      id = "test-suggestion:mesh_grid.rs:15",
      file = "mesh_grid.rs",
      diff = "@@ -750,2 +780,5 @@\n                .collect::<Vec<(u32, f32)>>();\n\n            edge_angles.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap());\n\n            *edges = edge_angles.into_iter().map(|(idx, _)| idx).collect();",
    },
    {
      id = "test-suggestion:mesh_grid.rs:16",
      file = "mesh_grid.rs",
      diff = "@@ -800,3 +832,6 @@\n        let mut offsets = Vec::with_capacity(num_vertices + 1);\n        let mut indices = Vec::new();\n\n        for edges in &vertex_edges {\n+            offsets.push(indices.len() as u32);\n+            indices.extend(edges);\n        }",
    },
    {
      id = "test-suggestion:mesh_grid.rs:17",
      file = "mesh_grid.rs",
      diff = "@@ -850,2 +884,5 @@\n        let num_triangles = indices.len() / 3;\n\n        let cell_adjacency = Adjacency::<Cell>::from(&sphere);\n        let cell_edge_adjacency = Adjacency::<CellEdge>::from(&sphere);",
    },
    {
      id = "test-suggestion:mesh_grid.rs:18",
      file = "mesh_grid.rs",
      diff = "@@ -900,3 +936,6 @@\n        let edge_vertex_adjacency = Adjacency::<EdgeVertex>::from(&sphere);\n        let vertex_cell_adjacency = Adjacency::<VertexCell>::from(&sphere);\n        let vertex_edge_adjacency = Adjacency::<VertexEdge>::from(&sphere);\n+        \n+        let num_vertices = points.len();",
    },
    {
      id = "test-suggestion:mesh_grid.rs:19",
      file = "mesh_grid.rs",
      diff = "@@ -950,2 +988,5 @@\n        let mut vertex_angle_offsets = vec![0.0f32; num_vertices];\n        let mut pole_vertices = Vec::new();\n        for vertex_idx in 0..num_vertices {\n            let vertex_pos: Vec3 = points[vertex_idx].into();",
    },
    {
      id = "test-suggestion:mesh_grid.rs:20",
      file = "mesh_grid.rs",
      diff = "@@ -1000,3 +1016,6 @@\n            let edge_dir_tangent =\n                (edge_dir - vertex_normal * edge_dir.dot(vertex_normal)).normalize();\n\n            let west_raw = vertex_normal.cross(Vec3::Y);\n+            if west_raw.length() < 0.05 * SPHERE_RADIUS {",
    },
  },
}

describe("shadow highlighting with realistic hunks", function()
  after_each(function()
    -- Clean up any open shadow buffers
    shadow.close()
  end)

  it("highlights all realistic hunks correctly", function()
    -- Create a test file with 1200 lines (similar to the actual mesh_grid.rs)
    local test_file = "/tmp/test_codeforge_realistic/mesh_grid.rs"
    vim.fn.mkdir("/tmp/test_codeforge_realistic", "p")
    local file = io.open(test_file, "w")
    for i = 1, 1200 do
      file:write("line" .. i .. "\n")
    end
    file:close()

    -- Set working directory
    shadow.set_working_dir("/tmp/test_codeforge_realistic")

    -- Test each hunk
    for i, hunk in ipairs(mock_suggestion.hunks) do
      -- Open shadow buffer for this hunk
      local buf, win = shadow.open(hunk, "/tmp/test_codeforge_realistic")

      -- Verify buffer was created
      assert.is_not_nil(buf)
      assert.is_true(vim.api.nvim_buf_is_valid(buf))

      -- Get the buffer content
      local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

      -- Parse the hunk to get expected added lines
      local changes = diff_utils.parse_diff_changes(hunk.diff)
      local expected_added_lines = {}
      for _, change in ipairs(changes) do
        if change.type == "add" then
          table.insert(expected_added_lines, change.content)
        end
      end

      -- Get highlights from the buffer
      local highlights = vim.api.nvim_buf_get_extmarks(buf, -1, {0, 0}, {-1, -1}, {details = true})

      -- Find all DiffAdd highlights
      local added_line_highlights = {}
      for _, mark in ipairs(highlights) do
        local row = mark[2]
        local details = mark[4]
        if details and details.hl_group == "DiffAdd" then
          table.insert(added_line_highlights, row)
        end
      end

      -- Verify we have the correct number of highlights
      assert.equals(#expected_added_lines, #added_line_highlights, 
        string.format("Hunk %d: Expected %d highlights, got %d", i, #expected_added_lines, #added_line_highlights))

      -- Verify the content of each highlighted line matches the expected content
      for j, row in ipairs(added_line_highlights) do
        local actual_content = content[row + 1]  -- +1 because content is 1-indexed
        local expected_content = expected_added_lines[j]
        assert.equals(expected_content, actual_content,
          string.format("Hunk %d, highlight %d: Expected '%s', got '%s'", i, j, expected_content, actual_content))
      end

      -- Close the shadow buffer before testing the next hunk
      shadow.close()
    end

    -- Clean up
    os.remove(test_file)
    vim.fn.delete("/tmp/test_codeforge_realistic", "rf")
  end)
end)
