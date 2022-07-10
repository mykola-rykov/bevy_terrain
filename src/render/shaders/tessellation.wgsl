#import bevy_terrain::config
#import bevy_terrain::parameters
#import bevy_terrain::patch

// Todo: increase workgroup size

struct CullData {
    world_position: vec4<f32>;
    view_proj: mat4x4<f32>;
    model: mat4x4<f32>;
    planes: array<vec4<f32>, 6>;
};

[[group(0), binding(0)]]
var<uniform> config: TerrainViewConfig;
[[group(0), binding(1)]]
var<storage, read_write> parameters: Parameters;
[[group(0), binding(2)]]
var<storage, read_write> temporary_patches: PatchList;
[[group(0), binding(3)]]
var<storage, read_write> final_patches: PatchList;

[[group(1), binding(0)]]
 var<uniform> cull_data: CullData;

//  MIT License. © Ian McEwan, Stefan Gustavson, Munrocket
//
fn permute3(x: vec3<f32>) -> vec3<f32> { return (((x * 34.) + 1.) * x) % vec3<f32>(289.); }

fn simplexNoise2(v: vec2<f32>) -> f32 {
    let C = vec4<f32>(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);
    var i: vec2<f32> = floor(v + dot(v, C.yy));
    let x0 = v - i + dot(i, C.xx);
    var i1: vec2<f32> = select(vec2<f32>(1., 0.), vec2<f32>(0., 1.), (x0.x > x0.y));
    var x12: vec4<f32> = x0.xyxy + C.xxzz - vec4<f32>(i1, 0., 0.);
    i = i % vec2<f32>(289.);
    let p = permute3(permute3(i.y + vec3<f32>(0., i1.y, 1.)) + i.x + vec3<f32>(0., i1.x, 1.));
    var m: vec3<f32> = max(0.5 -
        vec3<f32>(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), vec3<f32>(0.));
    m = m * m;
    m = m * m;
    let x = 2. * fract(p * C.www) - 1.;
    let h = abs(x) - 0.5;
    let ox = floor(x + 0.5);
    let a0 = x - ox;
    m = m * (1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h));
    let g = vec3<f32>(a0.x * x0.x + h.x * x0.y, a0.yz * x12.xz + h.yz * x12.yw);
    return (130. * dot(m, g) + 1.) / 2.;
}

fn child_index() -> i32 {
    return atomicAdd(&parameters.child_index, parameters.counter);
}

fn parent_index(id: u32) -> i32 {
    return i32(config.patch_count - 1u) * clamp(parameters.counter, 0, 1) - i32(id) * parameters.counter;
}

fn final_index(lod: u32) -> i32 {
    if (lod == 0u) {
        return atomicAdd(&parameters.final_index1, 1);
    }
    if (lod == 1u) {
        return atomicAdd(&parameters.final_index2, 1) + 100000;
    }
    if (lod == 2u) {
        return atomicAdd(&parameters.final_index3, 1) + 200000;
    }
    if (lod == 3u) {
        return atomicAdd(&parameters.final_index4, 1) + 300000;
    }
    return 0;
    // return atomicAdd(&parameters.final_indices[i32(lod)], 1) + i32(lod) * 1000000;
}

fn frustum_cull(position: vec2<f32>, size: f32) -> bool {
    let aabb_min = vec3<f32>(position.x, 0.0, position.y);
    let aabb_max = vec3<f32>(position.x + size, 1000.0, position.y + size);

    var corners = array<vec4<f32>, 8>(
        vec4<f32>(aabb_min.x, aabb_min.y, aabb_min.z, 1.0),
        vec4<f32>(aabb_min.x, aabb_min.y, aabb_max.z, 1.0),
        vec4<f32>(aabb_min.x, aabb_max.y, aabb_min.z, 1.0),
        vec4<f32>(aabb_min.x, aabb_max.y, aabb_max.z, 1.0),
        vec4<f32>(aabb_max.x, aabb_min.y, aabb_min.z, 1.0),
        vec4<f32>(aabb_max.x, aabb_min.y, aabb_max.z, 1.0),
        vec4<f32>(aabb_max.x, aabb_max.y, aabb_min.z, 1.0),
        vec4<f32>(aabb_max.x, aabb_max.y, aabb_max.z, 1.0)
    );

    for (var i = 0; i < 5; i = i + 1) {
        let plane = cull_data.planes[i];

        var in = 0u;

        for (var j = 0; j < 8; j = j + 1) {
            let corner = corners[j];

            if (dot(plane, corner) < 0.0) {
                in = in + 1u;
            }

            if (in == 0u) {
                return true;
            }
        }
    }

    return false;
}

fn divide(coords: vec2<u32>, size: u32) -> bool {
    var divide = false;

    for (var i: u32 = 0u; i < 4u; i = i + 1u) {
        let x = f32(coords.x + (i       & 1u));
        let y = f32(coords.y + (i >> 1u & 1u));

        let local_position = vec2<f32>(x, y) * config.patch_scale * f32(size);
        let world_position = vec3<f32>(local_position.x, config.height_under_viewer, local_position.y);
        let distance = length(cull_data.world_position.xyz - world_position) * 0.99; // consider adding a small error mitigation

        divide = divide || (distance < f32(size >> 1u) * config.view_distance);
    }

    return divide;
}

fn patch_lod(coords: vec2<u32>, size: u32) -> u32 {
    let local_position = (vec2<f32>(coords) + 0.5) * config.patch_scale * f32(size);
    return u32(simplexNoise2(local_position / 1600.0) * 4.0);
}

fn calc_border(outside_count: u32, coords: vec2<u32>, size: u32, i: i32) -> u32 {
    var test1 = array<vec2<u32>, 4>(
        vec2<u32>(1u, 0u),
        vec2<u32>(0u, 1u),
        vec2<u32>(0u, 0u),
        vec2<u32>(0u, 0u)

    );
    var test2 = array<vec2<u32>, 4>(
        vec2<u32>(1u, 1u),
        vec2<u32>(1u, 1u),
        vec2<u32>(0u, 1u),
        vec2<u32>(1u, 0u)
    );

    let left_coords  = (coords << vec2<u32>(1u)) + test1[i];
    let right_coords = (coords << vec2<u32>(1u)) + test2[i];
    let left_count  = calc_patch_count(patch_lod(left_coords,  size >> 1u));
    let right_count = calc_patch_count(patch_lod(right_coords, size >> 1u));
    let neighbour_child_count = min(left_count, right_count) << 1u;

    return min(outside_count, neighbour_child_count);
}

fn add_final_patch(patch: Patch) {
    var counts = 0u;
    var parent_counts = 0u;
    var directions = array<vec2<i32>, 4>(
        vec2<i32>(-1,  0),
        vec2<i32>( 0, -1),
        vec2<i32>( 1,  0),
        vec2<i32>( 0,  1)
    );


    var patch = patch;

#ifdef DENSITY
    let parent_coords = patch.coords >> vec2<u32>(1u);
    let parent_size = patch.size << 1u;

    var lod = patch_lod(patch.coords, patch.size);
    let count = calc_patch_count(lod);
    let parent_lod = patch_lod(parent_coords, parent_size);
    let parent_count = calc_patch_count(parent_lod) >> 1u;

    if (count < parent_count) {
        // can not morph into parrent with the current lod, thus choose a lod that fits the parent count
        lod = ((parent_count + 1u) >> 1u) - 1u;
    }

//    for (var i = 0; i < 4; i = i + 1) {
//        let neighbour_coords = vec2<u32>(vec2<i32>(patch.coords) + directions[i]);
//        let neighbour_parent_coords = neighbour_coords >> vec2<u32>(1u);
//
//        var edge_count: u32;
//        var edge_parent_count: u32;
//
//        if (divide(neighbour_parent_coords, parent_size)) {
//            if (divide(neighbour_coords, patch.size)) {
//                // neighours children are adjacent
//                // stitch with neighbour parent !!!
//                edge_count = calc_border(count, neighbour_coords, patch.size, i);
//                edge_parent_count = edge_count;
//                patch.padding = 1u;
//            }
//            else {
//                // neighour is adjacent
//                edge_count        = calc_patch_count(patch_lod(neighbour_coords,        patch.size));
//                edge_parent_count = calc_patch_count(patch_lod(neighbour_parent_coords, parent_size)) >> 1u;
//            }
//
//            edge_count        = calc_patch_count(patch_lod(neighbour_coords,        patch.size));
//            edge_parent_count = calc_patch_count(patch_lod(neighbour_parent_coords, parent_size)) >> 1u;
//        }
//        else {
//            // neighours parent is adjacent
//            let neighbour_count = calc_patch_count(patch_lod(neighbour_parent_coords, parent_size));
//
//            edge_count = calc_border(neighbour_count, parent_coords, parent_size, (i + 2) % 4) >> 1u;
//            edge_parent_count = edge_count;
//            patch.padding = 2u;
//        }
//
//        counts        = counts        | min(count,        edge_count)        << u32(i * 6);
//        parent_counts = parent_counts | min(parent_count, edge_parent_count) << u32(i * 6);
//    }

    for (var i = 0; i < 4; i = i + 1) {
        let neighbour_coords = vec2<u32>(vec2<i32>(patch.coords) + directions[i]);
        let neighbour_parent_coords = neighbour_coords >> vec2<u32>(1u);

        let edge_count        = calc_patch_count(patch_lod(neighbour_coords,        patch.size));
        let edge_parent_count = calc_patch_count(patch_lod(neighbour_parent_coords, parent_size)) >> 1u;

        counts        = counts        | min(count,        edge_count)        << u32(i * 6);
        parent_counts = parent_counts | min(parent_count, edge_parent_count) << u32(i * 6);
    }

#endif
#ifndef DENSITY
    let lod = 3u;
    let count = calc_patch_count(lod);
    let parent_count = (calc_patch_count(lod) >> 1u);

    for (var i = 0; i < 4; i = i + 1) {
        let shift = u32(i * 6);
        let neighbour_coords = vec2<u32>(vec2<i32>(patch.coords) + directions[i]);
        let neighbour_parent_coords = neighbour_coords >> vec2<u32>(1u);

        if (divide(neighbour_parent_coords, patch.size << 1u)) {
            counts = counts | count << shift;
        }
        else {
            counts = counts | parent_count << shift;
        }

        parent_counts = parent_counts | parent_count << shift;
    }
#endif

    counts        = counts        | count        << u32(4 * 6);
    parent_counts = parent_counts | parent_count << u32(4 * 6);

    patch.counts = counts;
    patch.parent_counts = parent_counts;
    final_patches.data[final_index(lod)] = patch;
}

[[stage(compute), workgroup_size(1, 1, 1)]]
fn select_coarsest_patches(
    [[builtin(global_invocation_id)]] invocation_id: vec3<u32>,
) {
    let x = invocation_id.x;
    let y = invocation_id.y;
    let size = 1u << config.refinement_count;

    temporary_patches.data[child_index()] = Patch(vec2<u32>(x, y), size, 0u, 0u, 0u);
}

[[stage(compute), workgroup_size(1, 1, 1)]]
fn refine_patches(
    [[builtin(global_invocation_id)]] invocation_id: vec3<u32>,
) {
    var parent_patch = temporary_patches.data[parent_index(invocation_id.x)];
    let parent_coords = parent_patch.coords;

    if (divide(parent_coords, parent_patch.size)) {
        let size = parent_patch.size >> 1u;

        for (var i: u32 = 0u; i < 4u; i = i + 1u) {
            let x = (parent_coords.x << 1u) + (i       & 1u);
            let y = (parent_coords.y << 1u) + (i >> 1u & 1u);

            // cull patches outside of the terrain
            let local_position = vec2<f32>(f32(x), f32(y)) * config.patch_scale * f32(size);
            if (local_position.x > f32(config.terrain_size) || local_position.y > f32(config.terrain_size)) {
                continue;
            }

            // if (frustum_cull(local_position, config.patch_scale * f32(config.patch_size * size))) {
            //     continue;
            // }

            temporary_patches.data[child_index()] = Patch(vec2<u32>(x, y), size, 0u, 0u, 0u);
        }
    }
    else {
        add_final_patch(parent_patch);
    }
}

[[stage(compute), workgroup_size(1, 1, 1)]]
fn select_finest_patches(
    [[builtin(global_invocation_id)]] invocation_id: vec3<u32>,
) {
    add_final_patch(temporary_patches.data[parent_index(invocation_id.x)]);
}


