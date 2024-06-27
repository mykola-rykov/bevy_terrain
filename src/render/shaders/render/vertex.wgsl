#define_import_path bevy_terrain::vertex

#import bevy_terrain::types::{Tile, Blend, NodeLookup}
#import bevy_terrain::bindings::{config, view_config, tiles}
#import bevy_terrain::functions::{lookup_node, compute_grid_offset, compute_local_position, compute_relative_position, compute_morph, compute_blend, normal_local_to_world, position_local_to_world}
#import bevy_terrain::debug::{show_tiles}
#import bevy_pbr::mesh_view_bindings::view
#import bevy_pbr::view_transformations::position_world_to_clip

struct VertexInput {
    @builtin(vertex_index) vertex_index: u32,
}

struct VertexOutput {
    @builtin(position)     clip_position: vec4<f32>,
    @location(0)           tile_index: u32,
    @location(1)           offset: vec2<f32>,
    @location(2)           view_distance: f32,
    @location(3)           world_normal: vec3<f32>,
    @location(4)           world_position: vec4<f32>,
    @location(5)           debug_color: vec4<f32>,
}

struct VertexInfo {
    tile_index: u32,
    tile: Tile,
    grid_offset: vec2<f32>,
    offset: vec2<f32>, // Todo: find better name
    world_position: vec3<f32>,
    world_normal: vec3<f32>,
    view_distance: f32,
    blend: Blend,
    taylor_error: f32,
}

fn vertex_info(input: VertexInput) -> VertexInfo {
    var info: VertexInfo;

    let tile_index = input.vertex_index / view_config.vertices_per_tile;
    let grid_index = input.vertex_index % view_config.vertices_per_tile;

    let grid_offset = compute_grid_offset(grid_index);

    info.tile_index  = tile_index;
    info.tile        = tiles[tile_index];
    info.grid_offset = grid_offset;
    info.offset      = grid_offset;

    var local_position  = compute_local_position(info.tile, info.grid_offset);
    info.world_position = position_local_to_world(local_position);
    info.world_normal   = normal_local_to_world(local_position);
    info.view_distance  = distance(info.world_position + view_config.approximate_height * info.world_normal, view.world_position);

#ifdef MORPH
    let morph           = compute_morph(info.view_distance, info.tile.lod, info.grid_offset);
    local_position      = compute_local_position(info.tile, morph.offset);
    info.world_position = position_local_to_world(local_position);
    info.world_normal   = normal_local_to_world(local_position);
    info.offset         = morph.offset;
#endif

#ifdef TEST1
    if (info.view_distance < view_config.precision_threshold_distance * config.scale) {
        var relative_position = compute_relative_position(info.tile, info.grid_offset);
        info.view_distance    = length(relative_position + view_config.approximate_height * info.world_normal);

    #ifdef MORPH
        let morph         = compute_morph(info.view_distance, info.tile.lod, info.grid_offset);
        relative_position = compute_relative_position(info.tile, morph.offset);
        info.offset       = morph.offset;
    #endif

        info.taylor_error = distance(info.world_position, view.world_position + relative_position);

        info.world_position = view.world_position + relative_position;
    }
#endif

    info.blend = compute_blend(info.view_distance);

    return info;
}

fn vertex_lookup_node(info: ptr<function, VertexInfo>, lod_offset: u32) -> NodeLookup {
    return lookup_node((*info).tile, (*info).offset, vec2<f32>(0.0), vec2<f32>(0.0), (*info).blend, lod_offset);
}

fn vertex_output(info: ptr<function, VertexInfo>, output: ptr<function, VertexOutput>, height: f32) {
    (*info).world_position = (*info).world_position + height * (*info).world_normal;
    (*info).view_distance  = distance((*info).world_position, view.world_position);

    (*output).tile_index     = (*info).tile_index;
    (*output).offset         = (*info).offset;
    (*output).view_distance  = (*info).view_distance;
    (*output).world_normal   = (*info).world_normal;
    (*output).world_position = vec4<f32>((*info).world_position, 1.0);
    (*output).clip_position  = position_world_to_clip((*info).world_position);
}

fn vertex_debug(info: ptr<function, VertexInfo>, output: ptr<function, VertexOutput>) {
#ifdef SHOW_TILES
    (*output).debug_color = show_tiles((*info).tile, (*info).view_distance);
#endif
#ifdef TEST2
    (*output).debug_color = vec4<f32>((*info).taylor_error / 1.0, 0.0, 0.0, 1.0);
#endif
}
