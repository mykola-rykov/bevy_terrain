use crate::{
    debug::DebugTerrain,
    render::{
        culling_bind_group::{create_culling_layout, CullingBindGroup},
        shaders::{PREPARE_INDIRECT_SHADER, REFINE_TILES_SHADER},
        terrain_bind_group::{create_terrain_layout, TerrainData},
        terrain_view_bind_group::{
            create_prepare_indirect_layout, create_refine_tiles_layout, TerrainViewData,
        },
    },
    terrain::{Terrain, TerrainComponents},
    terrain_view::{TerrainView, TerrainViewComponents},
};
use bevy::{
    prelude::*,
    render::{
        render_graph::{self, RenderLabel},
        render_resource::*,
        renderer::{RenderContext, RenderDevice},
    },
};
use strum::{EnumCount, IntoEnumIterator};
use strum_macros::{EnumCount, EnumIter};

#[derive(Debug, Hash, PartialEq, Eq, Clone, RenderLabel)]
pub struct TerrainComputeLabel;

type TerrainComputePipelineKey = (TerrainComputePipelineId, TerrainComputePipelineFlags);

#[derive(Copy, Clone, Hash, PartialEq, Eq, EnumIter, EnumCount)]
pub enum TerrainComputePipelineId {
    RefineTiles,
    PrepareRoot,
    PrepareNext,
    PrepareRender,
}

bitflags::bitflags! {
    #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
    #[repr(transparent)]
    pub struct TerrainComputePipelineFlags: u32 {
        const NONE               = 0;
        const SPHERICAL          = (1 << 0);
        const TEST               = (1 << 1);
    }
}

impl TerrainComputePipelineFlags {
    pub fn from_debug(debug: &DebugTerrain) -> Self {
        let mut key = TerrainComputePipelineFlags::NONE;

        if debug.test1 {
            key |= TerrainComputePipelineFlags::TEST;
        }

        key
    }

    pub fn shader_defs(&self) -> Vec<ShaderDefVal> {
        let mut shader_defs = Vec::new();

        if (self.bits() & TerrainComputePipelineFlags::SPHERICAL.bits()) != 0 {
            shader_defs.push("SPHERICAL".into());
        }
        if (self.bits() & TerrainComputePipelineFlags::TEST.bits()) != 0 {
            shader_defs.push("TEST".into());
        }

        shader_defs
    }
}

#[derive(Resource)]
pub struct TerrainComputePipelines {
    pub(crate) prepare_indirect_layout: BindGroupLayout,
    pub(crate) refine_tiles_layout: BindGroupLayout,
    culling_data_layout: BindGroupLayout,
    terrain_layout: BindGroupLayout,
    prepare_indirect_shader: Handle<Shader>,
    refine_tiles_shader: Handle<Shader>,
    pipelines: [Option<CachedComputePipelineId>; TerrainComputePipelineId::COUNT],
}

impl TerrainComputePipelines {
    pub(crate) fn queue(
        debug: Option<Res<DebugTerrain>>,
        pipeline_cache: Res<PipelineCache>,
        mut compute_pipelines: ResMut<TerrainComputePipelines>,
        mut pipelines: ResMut<SpecializedComputePipelines<TerrainComputePipelines>>,
    ) {
        let mut flags = TerrainComputePipelineFlags::NONE;

        #[cfg(feature = "spherical")]
        {
            flags |= TerrainComputePipelineFlags::SPHERICAL;
        }

        if let Some(debug) = &debug {
            flags |= TerrainComputePipelineFlags::from_debug(debug);
        }

        for id in TerrainComputePipelineId::iter() {
            compute_pipelines.pipelines[id as usize] =
                Some(pipelines.specialize(&pipeline_cache, &compute_pipelines, (id, flags)));
        }
    }
}

impl FromWorld for TerrainComputePipelines {
    fn from_world(world: &mut World) -> Self {
        let device = world.resource::<RenderDevice>();

        let prepare_indirect_layout = create_prepare_indirect_layout(device);
        let refine_tiles_layout = create_refine_tiles_layout(device);
        let culling_data_layout = create_culling_layout(device);
        let terrain_layout = create_terrain_layout(device);

        let prepare_indirect_shader = PREPARE_INDIRECT_SHADER;
        let refine_tiles_shader = REFINE_TILES_SHADER;

        TerrainComputePipelines {
            prepare_indirect_layout,
            refine_tiles_layout,
            culling_data_layout,
            terrain_layout,
            prepare_indirect_shader,
            refine_tiles_shader,
            pipelines: [None; TerrainComputePipelineId::COUNT],
        }
    }
}

impl SpecializedComputePipeline for TerrainComputePipelines {
    type Key = TerrainComputePipelineKey;

    fn specialize(&self, key: Self::Key) -> ComputePipelineDescriptor {
        let layout;
        let shader;
        let entry_point;

        let shader_defs = key.1.shader_defs();

        match key.0 {
            TerrainComputePipelineId::RefineTiles => {
                layout = vec![
                    self.culling_data_layout.clone(),
                    self.refine_tiles_layout.clone(),
                    self.terrain_layout.clone(),
                ];
                shader = self.refine_tiles_shader.clone();
                entry_point = "refine_tiles".into();
            }
            TerrainComputePipelineId::PrepareRoot => {
                layout = vec![
                    self.culling_data_layout.clone(),
                    self.refine_tiles_layout.clone(),
                    self.terrain_layout.clone(),
                    self.prepare_indirect_layout.clone(),
                ];
                shader = self.prepare_indirect_shader.clone();
                entry_point = "prepare_root".into();
            }
            TerrainComputePipelineId::PrepareNext => {
                layout = vec![
                    self.culling_data_layout.clone(),
                    self.refine_tiles_layout.clone(),
                    self.terrain_layout.clone(),
                    self.prepare_indirect_layout.clone(),
                ];
                shader = self.prepare_indirect_shader.clone();
                entry_point = "prepare_next".into();
            }
            TerrainComputePipelineId::PrepareRender => {
                layout = vec![
                    self.culling_data_layout.clone(),
                    self.refine_tiles_layout.clone(),
                    self.terrain_layout.clone(),
                    self.prepare_indirect_layout.clone(),
                ];
                shader = self.prepare_indirect_shader.clone();
                entry_point = "prepare_render".into();
            }
        }

        ComputePipelineDescriptor {
            label: Some("terrain_compute_pipeline".into()),
            layout,
            push_constant_ranges: default(),
            shader,
            shader_defs,
            entry_point,
        }
    }
}

pub struct TerrainComputeNode {
    terrain_query: QueryState<Entity, With<Terrain>>,
    view_query: QueryState<Entity, With<TerrainView>>,
}

impl FromWorld for TerrainComputeNode {
    fn from_world(world: &mut World) -> Self {
        Self {
            terrain_query: world.query_filtered(),
            view_query: world.query_filtered(),
        }
    }
}

impl TerrainComputeNode {
    fn tessellate_terrain<'a>(
        pass: &mut ComputePass<'a>,
        pipelines: &'a [&'a ComputePipeline],
        view_data: &'a TerrainViewData,
        terrain_data: &'a TerrainData,
        culling_bind_group: &'a CullingBindGroup,
    ) {
        pass.set_bind_group(0, culling_bind_group, &[]);
        pass.set_bind_group(1, &view_data.refine_tiles_bind_group, &[]);
        pass.set_bind_group(2, &terrain_data.terrain_bind_group, &[]);
        pass.set_bind_group(3, &view_data.prepare_indirect_bind_group, &[]);

        pass.set_pipeline(pipelines[TerrainComputePipelineId::PrepareRoot as usize]);
        pass.dispatch_workgroups(1, 1, 1);

        for _ in 0..view_data.refinement_count() {
            pass.set_pipeline(pipelines[TerrainComputePipelineId::RefineTiles as usize]);
            pass.dispatch_workgroups_indirect(&view_data.indirect_buffer, 0);

            pass.set_pipeline(pipelines[TerrainComputePipelineId::PrepareNext as usize]);
            pass.dispatch_workgroups(1, 1, 1);
        }

        pass.set_pipeline(pipelines[TerrainComputePipelineId::RefineTiles as usize]);
        pass.dispatch_workgroups_indirect(&view_data.indirect_buffer, 0);

        pass.set_pipeline(pipelines[TerrainComputePipelineId::PrepareRender as usize]);
        pass.dispatch_workgroups(1, 1, 1);
    }
}

impl render_graph::Node for TerrainComputeNode {
    fn update(&mut self, world: &mut World) {
        self.terrain_query.update_archetypes(world);
        self.view_query.update_archetypes(world);
    }

    fn run(
        &self,
        _graph: &mut render_graph::RenderGraphContext,
        context: &mut RenderContext,
        world: &World,
    ) -> Result<(), render_graph::NodeRunError> {
        let compute_pipelines = world.resource::<TerrainComputePipelines>();
        let pipeline_cache = world.resource::<PipelineCache>();
        let terrain_data = world.resource::<TerrainComponents<TerrainData>>();
        let terrain_view_data = world.resource::<TerrainViewComponents<TerrainViewData>>();
        let culling_bind_groups = world.resource::<TerrainViewComponents<CullingBindGroup>>();

        let debug = world.get_resource::<DebugTerrain>();

        if let Some(debug) = debug {
            if debug.freeze {
                return Ok(());
            }
        }

        let pipelines = &match TerrainComputePipelineId::iter()
            .map(|id| {
                pipeline_cache
                    .get_compute_pipeline(compute_pipelines.pipelines[id as usize].unwrap())
            })
            .collect::<Option<Vec<_>>>()
        {
            None => return Ok(()), // some pipelines are not loaded yet
            Some(pipelines) => pipelines,
        };

        let pass = &mut context
            .command_encoder()
            .begin_compute_pass(&ComputePassDescriptor::default());

        for terrain in self.terrain_query.iter_manual(world) {
            let terrain_data = terrain_data.get(&terrain).unwrap();

            for view in self.view_query.iter_manual(world) {
                let view_data = terrain_view_data.get(&(terrain, view)).unwrap();
                let culling_bind_group = culling_bind_groups.get(&(terrain, view)).unwrap();

                TerrainComputeNode::tessellate_terrain(
                    pass,
                    pipelines,
                    view_data,
                    terrain_data,
                    culling_bind_group,
                );
            }
        }

        Ok(())
    }
}
