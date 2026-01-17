use std::{f64::consts::TAU, marker::PhantomData, sync::Arc};

use bevy::{
    asset::RenderAssetUsages,
    math::DVec3,
    mesh::{Indices, PrimitiveTopology},
    platform::collections::HashMap,
    prelude::*,
    render::extract_resource::ExtractResource,
};
use hexasphere::shapes::IcoSphere;
use sprs::{CsMat, CsVec, TriMat};

use crate::constants::SPHERE_RADIUS;

#[derive(Debug, Clone)]
pub struct CellData {
    pub center: Vec3,
    pub vertices: [u32; 3],
}

/// Cell -> Cell adjacency marker
#[derive(Clone, Debug, Copy, Eq, PartialEq, Hash)]
pub struct Cell;

/// Vertex -> Cell adjacency marker
#[derive(Clone, Debug, Copy, Eq, PartialEq, Hash)]
pub struct VertexCell;

/// Edge -> Cell adjacency marker
#[derive(Clone, Debug, Copy, Eq, PartialEq, Hash)]
pub struct EdgeCell;

/// Edge -> Vertex adjacency marker
#[derive(Clone, Debug, Copy, Eq, PartialEq, Hash)]
pub struct EdgeVertex;

/// Cell -> Edge adjacency marker
#[derive(Clone, Debug, Copy, Eq, PartialEq, Hash)]
pub struct CellEdge;

/// Vertex -> Edge adjacency marker
#[derive(Clone, Debug, Copy, Eq, PartialEq, Hash)]
pub struct VertexEdge;

// NB: Structured this way to allow fast sharing between render and main world
#[derive(Resource, Clone)]
pub struct MeshGrid(Arc<MeshGridInner>);

impl MeshGrid {
    #[must_use]
    pub fn new(subdivisions: usize) -> Self {
        Self(Arc::new(MeshGridInner::new(subdivisions)))
    }

    #[must_use]
    pub fn mesh(&self) -> Mesh {
        self.0.mesh()
    }

    #[must_use]
    pub fn sphere(&self) -> &IcoSphere<Vec3A> {
        &self.0.sphere
    }

    #[must_use]
    pub fn cells(&self) -> &[CellData] {
        &self.0.cells
    }

    #[must_use]
    pub fn cell_adjacency(&self) -> &Adjacency<Cell> {
        &self.0.cell_adjacency
    }

    #[must_use]
    pub fn cell_edge_adjacency(&self) -> &Adjacency<CellEdge> {
        &self.0.cell_edge_adjacency
    }

    #[must_use]
    pub fn edge_cell_adjacency(&self) -> &Adjacency<EdgeCell> {
        &self.0.edge_cell_adjacency
    }

    #[must_use]
    pub fn edge_vertex_adjacency(&self) -> &Adjacency<EdgeVertex> {
        &self.0.edge_vertex_adjacency
    }

    #[must_use]
    pub fn vertex_cell_adjacency(&self) -> &Adjacency<VertexCell> {
        &self.0.vertex_cell_adjacency
    }

    #[must_use]
    pub fn vertex_edge_adjacency(&self) -> &Adjacency<VertexEdge> {
        &self.0.vertex_edge_adjacency
    }

    #[must_use]
    pub fn vertex_angle_offsets(&self) -> &[f32] {
        &self.0.vertex_angle_offsets
    }
}

/// CSR Adjacency data
pub struct Adjacency<T> {
    offsets: Vec<u32>,
    indices: Vec<u32>,
    _t: PhantomData<T>,
}

impl<T> Adjacency<T> {
    #[must_use]
    pub fn len(&self) -> usize {
        self.offsets.len().saturating_sub(1)
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    #[must_use]
    pub fn offsets(&self) -> &[u32] {
        &self.offsets
    }

    #[must_use]
    pub fn indices(&self) -> &[u32] {
        &self.indices
    }

    pub fn get(&self, idx: usize) -> impl Iterator<Item = usize> + '_ {
        let start = self.offsets[idx] as usize;
        let end = self.offsets[idx + 1] as usize;
        self.indices[start..end].iter().map(|&i| i as usize)
    }

    #[must_use]
    pub fn count(&self, idx: usize) -> usize {
        (self.offsets[idx + 1] - self.offsets[idx]) as usize
    }
}

impl<T> From<&IcoSphere<T>> for Adjacency<Cell> {
    fn from(sphere: &IcoSphere<T>) -> Self {
        let edge_cells = Adjacency::<EdgeCell>::from(sphere);
        let cell_edges = Adjacency::<CellEdge>::from(sphere);
        let num_cells = cell_edges.len();

        let mut offsets = Vec::with_capacity(num_cells + 1);
        let mut indices = Vec::with_capacity(num_cells * 3);

        for cell_idx in 0..num_cells {
            offsets.push(indices.len() as u32);

            for edge_idx in cell_edges.get(cell_idx) {
                let cells: Vec<_> = edge_cells.get(edge_idx).collect();
                let neighbor = if cells[0] == cell_idx {
                    cells[1]
                } else {
                    cells[0]
                };
                indices.push(neighbor as u32);
            }
        }

        offsets.push(indices.len() as u32);

        Self {
            offsets,
            indices,
            _t: PhantomData,
        }
    }
}

impl<T> From<&IcoSphere<T>> for Adjacency<CellEdge> {
    fn from(sphere: &IcoSphere<T>) -> Self {
        let mesh_indices = sphere.get_all_indices();
        let num_cells = mesh_indices.len() / 3;

        let mut edge_map: HashMap<(u32, u32), u32> = HashMap::new();
        let mut next_edge_idx = 0u32;

        for cell_idx in 0..num_cells {
            let base = cell_idx * 3;
            let cell_verts = [
                mesh_indices[base],
                mesh_indices[base + 1],
                mesh_indices[base + 2],
            ];

            for local_edge in 0..3 {
                let v0 = cell_verts[local_edge];
                let v1 = cell_verts[(local_edge + 1) % 3];
                let canonical = (v0.min(v1), v0.max(v1));

                edge_map.entry(canonical).or_insert_with(|| {
                    let idx = next_edge_idx;
                    next_edge_idx += 1;
                    idx
                });
            }
        }
        let mut offsets = Vec::with_capacity(num_cells + 1);
        let mut indices = Vec::with_capacity(num_cells * 3);

        for cell_idx in 0..num_cells {
            offsets.push(indices.len() as u32);

            let base = cell_idx * 3;
            let cell_verts = [
                mesh_indices[base],
                mesh_indices[base + 1],
                mesh_indices[base + 2],
            ];

            for local_edge in 0..3 {
                let v0 = cell_verts[local_edge];
                let v1 = cell_verts[(local_edge + 1) % 3];
                let canonical = (v0.min(v1), v0.max(v1));
                let edge_idx = edge_map[&canonical];
                indices.push(edge_idx);
            }
        }

        offsets.push(indices.len() as u32);

        Self {
            offsets,
            indices,
            _t: PhantomData,
        }
    }
}

impl<T> From<&IcoSphere<T>> for Adjacency<EdgeCell> {
    fn from(sphere: &IcoSphere<T>) -> Self {
        let mesh_indices = sphere.get_all_indices();
        let num_cells = mesh_indices.len() / 3;

        let mut edge_map: HashMap<(u32, u32), (usize, [u32; 2], usize)> = HashMap::new();
        let mut next_edge_idx = 0usize;

        for cell_idx in 0..num_cells {
            let base = cell_idx * 3;
            let cell_verts = [
                mesh_indices[base],
                mesh_indices[base + 1],
                mesh_indices[base + 2],
            ];

            for local_edge in 0..3 {
                let v0 = cell_verts[local_edge];
                let v1 = cell_verts[(local_edge + 1) % 3];
                let canonical = (v0.min(v1), v0.max(v1));
                let is_primary = v0 < v1;

                let entry = edge_map.entry(canonical).or_insert_with(|| {
                    let idx = next_edge_idx;
                    next_edge_idx += 1;
                    (idx, [0, 0], 0)
                });

                let slot = if is_primary { 0 } else { 1 };
                entry.1[slot] = cell_idx as u32;
                entry.2 += 1;
            }
        }

        let num_edges = edge_map.len();

        let mut offsets = Vec::with_capacity(num_edges + 1);
        let mut indices = vec![0u32; num_edges * 2];

        for (edge_idx, cells, _) in edge_map.values() {
            let offset = edge_idx * 2;
            indices[offset] = cells[0];
            indices[offset + 1] = cells[1];
        }

        for i in 0..=num_edges {
            offsets.push((i * 2) as u32);
        }

        Self {
            offsets,
            indices,
            _t: PhantomData,
        }
    }
}

impl<T> From<&IcoSphere<T>> for Adjacency<EdgeVertex> {
    fn from(sphere: &IcoSphere<T>) -> Self {
        let mesh_indices = sphere.get_all_indices();
        let num_cells = mesh_indices.len() / 3;

        let mut edge_set: HashMap<(u32, u32), usize> = HashMap::new();
        let mut next_edge_idx = 0usize;

        for cell_idx in 0..num_cells {
            let base = cell_idx * 3;
            let cell_verts = [
                mesh_indices[base],
                mesh_indices[base + 1],
                mesh_indices[base + 2],
            ];

            for local_edge in 0..3 {
                let v0 = cell_verts[local_edge];
                let v1 = cell_verts[(local_edge + 1) % 3];
                let canonical = (v0.min(v1), v0.max(v1));

                edge_set.entry(canonical).or_insert_with(|| {
                    let idx = next_edge_idx;
                    next_edge_idx += 1;
                    idx
                });
            }
        }

        let num_edges = edge_set.len();

        let mut offsets = Vec::with_capacity(num_edges + 1);
        let mut indices = vec![0u32; num_edges * 2];

        for ((v_lower, v_higher), edge_idx) in &edge_set {
            let offset = edge_idx * 2;
            indices[offset] = *v_lower;
            indices[offset + 1] = *v_higher;
        }

        for i in 0..=num_edges {
            offsets.push((i * 2) as u32);
        }

        Self {
            offsets,
            indices,
            _t: PhantomData,
        }
    }
}

impl<T> From<&IcoSphere<T>> for Adjacency<VertexCell> {
    fn from(sphere: &IcoSphere<T>) -> Self {
        let points = sphere.raw_points();
        let mesh_indices = sphere.get_all_indices();
        let num_vertices = points.len();
        let num_cells = mesh_indices.len() / 3;

        let mut counts = vec![0u32; num_vertices];
        for cell_idx in 0..num_cells {
            let base = cell_idx * 3;
            counts[mesh_indices[base] as usize] += 1;
            counts[mesh_indices[base + 1] as usize] += 1;
            counts[mesh_indices[base + 2] as usize] += 1;
        }

        let mut offsets = Vec::with_capacity(num_vertices + 1);
        let mut running = 0u32;
        for &count in &counts {
            offsets.push(running);
            running += count;
        }
        offsets.push(running);

        let mut write_pos = offsets[..num_vertices].to_vec();
        let mut indices = vec![0u32; running as usize];

        for cell_idx in 0..num_cells {
            let base = cell_idx * 3;
            for i in 0..3 {
                let v = mesh_indices[base + i] as usize;
                indices[write_pos[v] as usize] = cell_idx as u32;
                write_pos[v] += 1;
            }
        }

        Self {
            offsets,
            indices,
            _t: PhantomData,
        }
    }
}

impl<T> From<&IcoSphere<T>> for Adjacency<VertexEdge> {
    fn from(sphere: &IcoSphere<T>) -> Self {
        let points = sphere.raw_points();
        let num_vertices = points.len();
        let edge_vertex = Adjacency::<EdgeVertex>::from(sphere);
        let num_edges = edge_vertex.len();

        let mut vertex_edges = vec![Vec::new(); num_vertices];
        for edge_idx in 0..num_edges {
            let verts = edge_vertex.get(edge_idx).collect::<Vec<_>>();
            let v_lower = verts[0];
            let v_higher = verts[1];
            vertex_edges[v_lower].push(edge_idx as u32);
            vertex_edges[v_higher].push(edge_idx as u32);
        }

        for (vertex_idx, edges) in vertex_edges.iter_mut().enumerate() {
            // Create a tangent plane to the surface, then project the
            // direction from the central vertex to the other neighboring
            // vertices onto the tangent plane, then sort by the angle
            // created.
            let vertex_pos: Vec3 = points[vertex_idx].into();
            let vertex_normal = vertex_pos.normalize();

            let is_pole = vertex_normal.x.abs() < 1e-6
                && vertex_normal.z.abs() < 1e-6
                && (vertex_normal.y.abs() - 1.0).abs() < 1e-6;

            let up = if is_pole { Vec3::X } else { Vec3::Y };

            let tangent_x = vertex_normal.cross(up).normalize();
            let tangent_y = tangent_x.cross(vertex_normal).normalize();

            let mut edge_angles = edges
                .iter()
                .map(|&edge_idx| {
                    let verts = edge_vertex.get(edge_idx as usize).collect::<Vec<_>>();
                    let other_vertex = if verts[0] == vertex_idx {
                        verts[1]
                    } else {
                        verts[0]
                    };
                    let other_pos: Vec3 = points[other_vertex].into();
                    let direction = (other_pos - vertex_pos).normalize();

                    let proj_x = direction.dot(tangent_x);
                    let proj_y = direction.dot(tangent_y);
                    let angle = proj_y.atan2(proj_x);

                    (edge_idx, angle)
                })
                .collect::<Vec<(u32, f32)>>();

            edge_angles.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap());

            *edges = edge_angles.into_iter().map(|(idx, _)| idx).collect();
        }

        let mut offsets = Vec::with_capacity(num_vertices + 1);
        let mut indices = Vec::new();

        for edges in &vertex_edges {
            offsets.push(indices.len() as u32);
            indices.extend(edges);
        }

        offsets.push(indices.len() as u32);

        Self {
            offsets,
            indices,
            _t: PhantomData,
        }
    }
}

struct MeshGridInner {
    pub cell_adjacency: Adjacency<Cell>,
    pub cell_edge_adjacency: Adjacency<CellEdge>,
    pub cells: Vec<CellData>,
    pub edge_cell_adjacency: Adjacency<EdgeCell>,
    pub edge_vertex_adjacency: Adjacency<EdgeVertex>,
    pub sphere: IcoSphere<Vec3A>,
    pub vertex_cell_adjacency: Adjacency<VertexCell>,
    pub vertex_edge_adjacency: Adjacency<VertexEdge>,
    pub vertex_angle_offsets: Vec<f32>,
    pub edge_transport_connection: Vec<f32>,
}

impl ExtractResource for MeshGrid {
    type Source = MeshGrid;

    fn extract_resource(source: &Self::Source) -> Self {
        source.clone()
    }
}

impl MeshGridInner {
    #[must_use]
    #[allow(clippy::too_many_lines)]
    pub fn new(subdivisions: usize) -> Self {
        let sphere = IcoSphere::new(subdivisions, |v| v * SPHERE_RADIUS);
        let points = sphere.raw_points();
        let indices = sphere.get_all_indices();
        let num_triangles = indices.len() / 3;

        let cell_adjacency = Adjacency::<Cell>::from(&sphere);
        let cell_edge_adjacency = Adjacency::<CellEdge>::from(&sphere);
        let edge_cell_adjacency = Adjacency::<EdgeCell>::from(&sphere);
        let edge_vertex_adjacency = Adjacency::<EdgeVertex>::from(&sphere);
        let vertex_cell_adjacency = Adjacency::<VertexCell>::from(&sphere);
        let vertex_edge_adjacency = Adjacency::<VertexEdge>::from(&sphere);

        let num_vertices = points.len();
        let mut vertex_angle_offsets = vec![0.0f32; num_vertices];
        let mut pole_vertices = Vec::new();
        for vertex_idx in 0..num_vertices {
            let vertex_pos: Vec3 = points[vertex_idx].into();
            let vertex_normal = vertex_pos.normalize();

            let is_pole = vertex_normal.x.abs() < 1e-7
                && vertex_normal.z.abs() < 1e-7
                && (vertex_normal.y.abs() - SPHERE_RADIUS).abs() < 1e-7;

            if is_pole {
                pole_vertices.push(vertex_idx);
                continue;
            }

            let edge_0_idx = vertex_edge_adjacency
                .get(vertex_idx)
                .next()
                .expect("there to be an edge on the vertex");

            let edge_0_verts = edge_vertex_adjacency.get(edge_0_idx).collect::<Vec<_>>();
            let v_other = if edge_0_verts[0] == vertex_idx {
                edge_0_verts[1]
            } else {
                edge_0_verts[0]
            };
            let other_pos: Vec3 = points[v_other].into();
            let edge_dir = (other_pos - vertex_pos).normalize();

            let edge_dir_tangent =
                (edge_dir - vertex_normal * edge_dir.dot(vertex_normal)).normalize();

            let west_raw = vertex_normal.cross(Vec3::Y);
            if west_raw.length() < 0.05 * SPHERE_RADIUS {
                pole_vertices.push(vertex_idx);
                continue;
            }

            let west = west_raw.normalize();
            let north = west.cross(vertex_normal).normalize();
            let angle_offset = edge_dir_tangent
                .dot(north)
                .atan2(edge_dir_tangent.dot(west));

            vertex_angle_offsets[vertex_idx] = angle_offset;
        }

        for &pole_idx in &pole_vertices {
            let pole_pos: Vec3 = points[pole_idx].into();
            let pole_normal = pole_pos.normalize();

            let edge_0_idx = vertex_edge_adjacency
                .get(pole_idx)
                .next()
                .expect("to have pole vertex edge");
            let edge_0_verts = edge_vertex_adjacency.get(edge_0_idx).collect::<Vec<_>>();
            let neighbor_idx = if edge_0_verts[0] == pole_idx {
                edge_0_verts[1]
            } else {
                edge_0_verts[0]
            };

            let neighbor_pos: Vec3 = points[neighbor_idx].into();
            let neighbor_normal = neighbor_pos.normalize();
            let neighbor_west = neighbor_normal.cross(Vec3::Y).normalize();
            let neighbor_north = neighbor_west.cross(neighbor_normal).normalize();

            let edge_dir = (neighbor_pos - pole_pos).normalize();
            let edge_dir_tangent = (edge_dir - pole_normal * edge_dir.dot(pole_normal)).normalize();

            let neighbor_west_at_pole =
                (neighbor_west - pole_normal * neighbor_west.dot(pole_normal)).normalize();
            let neighbor_north_at_pole =
                (neighbor_north - pole_normal * neighbor_north.dot(pole_normal)).normalize();

            let angle_offset = edge_dir_tangent
                .dot(neighbor_north_at_pole)
                .atan2(edge_dir_tangent.dot(neighbor_west_at_pole));

            vertex_angle_offsets[pole_idx] = angle_offset;
        }

        let mut cells = Vec::new();
        for tri_idx in 0..num_triangles {
            let base = tri_idx * 3;
            let v0 = indices[base];
            let v1 = indices[base + 1];
            let v2 = indices[base + 2];

            let p0: Vec3 = (SPHERE_RADIUS * points[v0 as usize]).into();
            let p1: Vec3 = (SPHERE_RADIUS * points[v1 as usize]).into();
            let p2: Vec3 = (SPHERE_RADIUS * points[v2 as usize]).into();

            let center = (p0 + p1 + p2) / 3.0;

            cells.push(CellData {
                center,
                vertices: [v0, v1, v2],
            });
        }

        // let edge_transport_connection = Self::calculate_trivial_connection(grid, &[]);
        let edge_transport_connection = vec![];

        Self {
            cell_adjacency,
            cell_edge_adjacency,
            cells,
            edge_cell_adjacency,
            edge_vertex_adjacency,
            sphere,
            vertex_cell_adjacency,
            vertex_edge_adjacency,
            vertex_angle_offsets,
            edge_transport_connection,
        }
    }

    #[must_use]
    pub fn mesh(&self) -> Mesh {
        let points = self.sphere.raw_points();
        let indices = self.sphere.get_all_indices();

        let positions = points
            .iter()
            .map(|&p| (SPHERE_RADIUS * p).into())
            .collect::<Vec<[f32; 3]>>();
        let normals = points
            .iter()
            .map(|&p| p.normalize().into())
            .collect::<Vec<[f32; 3]>>();

        let mut mesh = Mesh::new(PrimitiveTopology::TriangleList, RenderAssetUsages::all());

        mesh.insert_attribute(Mesh::ATTRIBUTE_POSITION, positions);
        mesh.insert_attribute(Mesh::ATTRIBUTE_NORMAL, normals);
        mesh.insert_indices(Indices::U32(indices));
        mesh
    }

    fn calculate_trivial_connection(grid: &MeshGrid, singularities: &[(usize, usize)]) -> Vec<f32> {
        let d0 = Self::build_d0(
            grid.edge_vertex_adjacency(),
            grid.vertex_edge_adjacency().len(),
        );
        let d1 = Self::build_d1(
            grid.cell_edge_adjacency(),
            grid.edge_vertex_adjacency(),
            grid.sphere(),
        );
        let curvature = Self::calculate_gaussian_curvature(
            grid.sphere(),
            grid.vertex_edge_adjacency(),
            grid.edge_vertex_adjacency(),
        );

        let num_vertices = curvature.len();
        let num_edges = grid.edge_vertex_adjacency().len();

        let mut rhs_data = vec![0.0; num_vertices];
        for i in 0..num_vertices {
            rhs_data[i] = -curvature[i];
        }

        for &(vertex_idx, index) in singularities {
            rhs_data[vertex_idx] += TAU * (index as f64);
        }

        let rhs = CsVec::new(num_vertices, (0..num_vertices).collect(), rhs_data);
        todo!();
        vec![]
    }

    fn calculate_gaussian_curvature(
        sphere: &IcoSphere<Vec3A>,
        vertex_edge_adjacency: &Adjacency<VertexEdge>,
        edge_vertex_adjacency: &Adjacency<EdgeVertex>,
    ) -> Vec<f64> {
        let mut curvature = vec![0.0; vertex_edge_adjacency.len()];
        for i in 0..vertex_edge_adjacency.len() {
            let mut angle_sum = 0.0;
            let mut prev_edge_dir = DVec3::default();
            let mut adjacent_edges = vertex_edge_adjacency.get(i).collect::<Vec<_>>();
            adjacent_edges.push(adjacent_edges[0]);
            for (e_i, &edge) in adjacent_edges.iter().enumerate() {
                let other_vertex = {
                    let mut next_edge_iter = edge_vertex_adjacency.get(edge);
                    if let Some(j) = next_edge_iter.next()
                        && j != i
                    {
                        j
                    } else {
                        next_edge_iter.next().expect("to have vertex for edge")
                    }
                };

                let dir = sphere.raw_points()[other_vertex] - sphere.raw_points()[i];
                let dir_64 = DVec3::from(Vec3::from(dir));

                if e_i != 0 {
                    angle_sum += prev_edge_dir.angle_between(dir_64);
                }

                prev_edge_dir = dir_64;
            }

            curvature[i] = TAU - angle_sum;
        }

        curvature
    }

    fn build_d0(edge_vertex_adjacency: &Adjacency<EdgeVertex>, num_vertices: usize) -> CsMat<f64> {
        let num_edges = edge_vertex_adjacency.len();
        let mut d0_triplet = TriMat::new((num_edges, num_vertices));

        for edge_idx in 0..num_edges {
            let verts = edge_vertex_adjacency.get(edge_idx).collect::<Vec<_>>();
            let v_lower = verts[0];
            let v_higher = verts[1];

            d0_triplet.add_triplet(edge_idx, v_lower, -1.0);
            d0_triplet.add_triplet(edge_idx, v_higher, 1.0);
        }

        d0_triplet.to_csr()
    }

    fn build_d1(
        cell_edge_adjacency: &Adjacency<CellEdge>,
        edge_vertex_adjacency: &Adjacency<EdgeVertex>,
        sphere: &IcoSphere<Vec3A>,
    ) -> CsMat<f64> {
        let num_cells = cell_edge_adjacency.len();
        let num_edges = edge_vertex_adjacency.len();
        let indices = sphere.get_all_indices();

        let mut d1_triplet = TriMat::new((num_cells, num_edges));

        for cell_idx in 0..num_cells {
            let base = cell_idx * 3;
            let cell_verts = [indices[base], indices[base + 1], indices[base + 2]];

            for local_edge in 0..3 {
                let v_start = cell_verts[local_edge];

                let edge_idx = cell_edge_adjacency
                    .get(cell_idx)
                    .nth(local_edge)
                    .expect("to have cell edge");

                let canonical_v_lower = edge_vertex_adjacency
                    .get(edge_idx)
                    .next()
                    .expect("to have edge vertex");
                let sign = if canonical_v_lower as u32 == v_start {
                    -1.0
                } else {
                    1.0
                };

                d1_triplet.add_triplet(cell_idx, edge_idx, sign);
            }
        }

        d1_triplet.to_csr()
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn it_calculates_curvature() {
        let grid = MeshGrid::new(100);
        let curvature = MeshGridInner::calculate_gaussian_curvature(
            grid.sphere(),
            grid.vertex_edge_adjacency(),
            grid.edge_vertex_adjacency(),
        );

        let total_curvature = curvature.iter().fold(0.0, |acc, &x| acc + x);

        assert!(
            (total_curvature - 2.0 * TAU).abs() < 1.5e-3,
            "{}",
            (total_curvature - 2.0 * TAU).abs()
        );
    }

    #[test]
    fn it_is_zero_when_applying_d_twice() {
        let grid = MeshGrid::new(0);

        let d0 = MeshGridInner::build_d0(
            grid.edge_vertex_adjacency(),
            grid.vertex_edge_adjacency().len(),
        );
        let d1 = MeshGridInner::build_d1(
            grid.cell_edge_adjacency(),
            grid.edge_vertex_adjacency(),
            grid.sphere(),
        );

        let product = &d1 * &d0;
        let max_val = product
            .iter()
            .fold(0.0, |acc: f64, (&x, _)| acc.max(x.abs()));

        assert!(max_val < f64::EPSILON);
    }

    #[test]
    fn it_sums_to_zero_for_d0() {
        let grid = MeshGrid::new(0);

        let d0 = MeshGridInner::build_d0(
            grid.edge_vertex_adjacency(),
            grid.vertex_edge_adjacency().len(),
        );

        for row_vec in d0.outer_iterator() {
            let sum = row_vec.iter().fold(0.0, |acc, (_, &x)| acc + x);
            assert!(sum < f64::EPSILON);
        }
    }
}
