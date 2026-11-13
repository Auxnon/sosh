//! sosh for the desktop: the social client (servers, chat, friends,
//! pictures) in egui on wgpu, styled like the Android app. The world and
//! shared carts are Petrichor64 instances on the same device, drawn into
//! the window as egui pictures (`stage.rs`).
//!
//! `sosh --snapshot out.png [--size 1280x800] [--secs 6] [--click x,y]...`
//! draws the app without a window (no display needed) and writes a picture:
//! for checking layouts. `--click`s land a second apart once it's loaded,
//! then `--type TEXT` (and Enter).

// a windowed app on Windows: no console window behind it (debug builds keep one for logs)
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod media;
mod models;
mod net;
mod stage;
mod state;
mod store;
mod theme;
mod ui;

use std::sync::Arc;
use std::time::{Duration, Instant};

use winit::application::ApplicationHandler;
use winit::event::WindowEvent;
use winit::event_loop::{ActiveEventLoop, ControlFlow, EventLoop, EventLoopProxy};
use winit::window::{Window, WindowId};

use crate::state::State;

struct Gpu {
    adapter: wgpu::Adapter,
    device: wgpu::Device,
    queue: wgpu::Queue,
}

fn instance(display: Option<Box<dyn wgpu::wgt::WgpuHasDisplayHandle>>) -> wgpu::Instance {
    let mut desc = match display {
        Some(d) => wgpu::InstanceDescriptor::new_with_display_handle(d),
        None => wgpu::InstanceDescriptor::new_without_display_handle(),
    };
    desc.backends = if cfg!(target_vendor = "apple") {
        wgpu::Backends::METAL
    } else if cfg!(target_os = "windows") {
        wgpu::Backends::DX12 | wgpu::Backends::GL
    } else {
        wgpu::Backends::VULKAN | wgpu::Backends::GL
    };
    wgpu::Instance::new(desc)
}

fn open_gpu(instance: &wgpu::Instance, surface: Option<&wgpu::Surface<'_>>) -> Result<Gpu, String> {
    let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
        power_preference: wgpu::PowerPreference::None,
        force_fallback_adapter: false,
        compatible_surface: surface,
        apply_limit_buckets: false,
    }))
    .map_err(|e| format!("no GPU adapter: {e}"))?;
    let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
        label: Some("sosh"),
        required_features: wgpu::Features::empty(),
        required_limits: wgpu::Limits::downlevel_webgl2_defaults().using_resolution(adapter.limits()),
        experimental_features: wgpu::ExperimentalFeatures::disabled(),
        memory_hints: wgpu::MemoryHints::MemoryUsage,
        trace: wgpu::Trace::Off,
    }))
    .map_err(|e| format!("no GPU device: {e}"))?;
    device.on_uncaptured_error(Arc::new(|e| log::error!("wgpu: {e}")));
    Ok(Gpu { adapter, device, queue })
}

fn draw_egui(
    renderer: &mut egui_wgpu::Renderer,
    gpu: &Gpu,
    target: &wgpu::TextureView,
    jobs: &[egui::ClippedPrimitive],
    screen: &egui_wgpu::ScreenDescriptor,
) {
    let mut enc = gpu.device.create_command_encoder(&Default::default());
    let extra = renderer.update_buffers(&gpu.device, &gpu.queue, &mut enc, jobs, screen);
    {
        let mut pass = enc
            .begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("egui"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: target,
                    depth_slice: None,
                    resolve_target: None,
                    // the ground (NIGHT), which the UI paints over anyway
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color { r: 0.018, g: 0.013, b: 0.074, a: 1.0 }),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            })
            .forget_lifetime();
        renderer.render(&mut pass, jobs, screen);
    }
    gpu.queue.submit(extra.into_iter().chain(std::iter::once(enc.finish())));
}

/// One frame of the UI: what's arrived, then the screens.
fn run_ui(egui: &egui::Context, raw: egui::RawInput, st: &mut State, view: &mut ui::View) -> egui::FullOutput {
    st.pump();
    egui.run_ui(raw, |root| ui::draw(root, st, view))
}

struct Win {
    window: Arc<Window>,
    surface: wgpu::Surface<'static>,
    config: wgpu::SurfaceConfiguration,
    gpu: Gpu,
    egui: egui::Context,
    egui_state: egui_winit::State,
    renderer: egui_wgpu::Renderer,
    state: State,
    view: ui::View,
    stages: stage::Stages,
}

struct App {
    proxy: EventLoopProxy<()>,
    win: Option<Win>,
    next: Option<Instant>,
}

impl ApplicationHandler for App {
    fn resumed(&mut self, el: &ActiveEventLoop) {
        if self.win.is_some() {
            return;
        }
        let attrs = Window::default_attributes()
            .with_title("sosh")
            .with_inner_size(winit::dpi::LogicalSize::new(1280.0, 820.0))
            .with_min_inner_size(winit::dpi::LogicalSize::new(380.0, 520.0));
        #[cfg(target_os = "linux")]
        let attrs = {
            use winit::platform::wayland::WindowAttributesExtWayland;
            attrs.with_name("sosh", "sosh")
        };
        let window = Arc::new(el.create_window(attrs).expect("window"));
        let inst = instance(Some(Box::new(el.owned_display_handle())));
        let surface = inst.create_surface(window.clone()).expect("surface");
        let gpu = match open_gpu(&inst, Some(&surface)) {
            Ok(g) => g,
            Err(e) => {
                eprintln!("sosh: {e}");
                el.exit();
                return;
            }
        };
        let caps = surface.get_capabilities(&gpu.adapter);
        // egui blends in gamma space, so it wants a plain (not sRGB) target
        let format = caps.formats.iter().copied().find(|f| !f.is_srgb()).unwrap_or(caps.formats[0]);
        let size = window.inner_size();
        let config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format,
            width: size.width.max(1),
            height: size.height.max(1),
            present_mode: wgpu::PresentMode::Fifo,
            desired_maximum_frame_latency: 2,
            alpha_mode: caps.alpha_modes[0],
            view_formats: vec![],
            color_space: wgpu::SurfaceColorSpace::Auto,
        };
        surface.configure(&gpu.device, &config);
        let renderer = egui_wgpu::Renderer::new(&gpu.device, format, egui_wgpu::RendererOptions::default());
        let egui = egui::Context::default();
        theme::setup(&egui);
        let max_tex = gpu.device.limits().max_texture_dimension_2d as usize;
        let egui_state =
            egui_winit::State::new(egui.clone(), egui::ViewportId::ROOT, &window, Some(window.scale_factor() as f32), window.theme(), Some(max_tex));
        // anything off the UI thread (the socket, calls) wakes the window
        let proxy = self.proxy.clone();
        let wake: state::Wake = Arc::new(move || {
            let _ = proxy.send_event(());
        });
        let repaint = self.proxy.clone();
        egui.set_request_repaint_callback(move |_| {
            let _ = repaint.send_event(());
        });
        let state = State::new(egui.clone(), wake);
        let stages = stage::Stages::new(&gpu.device, &gpu.queue);
        window.request_redraw();
        self.win = Some(Win { window, surface, config, gpu, egui, egui_state, renderer, state, view: ui::View::default(), stages });
    }

    fn user_event(&mut self, _el: &ActiveEventLoop, _: ()) {
        if let Some(w) = &self.win {
            w.window.request_redraw();
        }
    }

    fn window_event(&mut self, el: &ActiveEventLoop, _id: WindowId, event: WindowEvent) {
        let Some(w) = self.win.as_mut() else { return };
        let resp = w.egui_state.on_window_event(&w.window, &event);
        // the world or a cart under the pointer (or with the keys) hears it too
        let typing = w.egui.egui_wants_keyboard_input();
        w.stages.event(&mut w.state, &event, typing);
        if resp.repaint {
            w.window.request_redraw();
        }
        match event {
            WindowEvent::CloseRequested => el.exit(),
            WindowEvent::Resized(s) => {
                w.config.width = s.width.max(1);
                w.config.height = s.height.max(1);
                w.surface.configure(&w.gpu.device, &w.config);
                w.window.request_redraw();
            }
            // a picture (or a .game.png) dropped on the window goes to the open chat
            WindowEvent::DroppedFile(path) => {
                w.state.share_path(&path);
                w.window.request_redraw();
            }
            WindowEvent::RedrawRequested => {
                let raw = w.egui_state.take_egui_input(&w.window);
                let mut out = run_ui(&w.egui, raw, &mut w.state, &mut w.view);
                w.egui_state.handle_platform_output(&w.window, out.platform_output);
                let ppp = out.pixels_per_point;
                // the world and a cart draw first, into their textures
                w.stages.update(&mut w.state, &mut w.renderer, ppp);
                let jobs = w.egui.tessellate(out.shapes, ppp);
                for (id, deltas) in &out.textures_delta.set {
                    for delta in deltas {
                        w.renderer.update_texture(&w.gpu.device, &w.gpu.queue, *id, delta);
                    }
                }
                let screen = egui_wgpu::ScreenDescriptor { size_in_pixels: [w.config.width, w.config.height], pixels_per_point: ppp };
                match w.surface.get_current_texture() {
                    wgpu::CurrentSurfaceTexture::Success(frame) | wgpu::CurrentSurfaceTexture::Suboptimal(frame) => {
                        let view = frame.texture.create_view(&Default::default());
                        draw_egui(&mut w.renderer, &w.gpu, &view, &jobs, &screen);
                        w.window.pre_present_notify();
                        w.gpu.queue.present(frame);
                    }
                    wgpu::CurrentSurfaceTexture::Outdated | wgpu::CurrentSurfaceTexture::Lost => {
                        w.surface.configure(&w.gpu.device, &w.config);
                        w.window.request_redraw();
                    }
                    _ => {}
                }
                for id in &out.textures_delta.free {
                    w.renderer.free_texture(id);
                }
                out.textures_delta.clear();
                let delay = out.viewport_output.get(&egui::ViewportId::ROOT).map_or(Duration::MAX, |v| v.repaint_delay);
                let egui_next = if delay.is_zero() {
                    w.window.request_redraw();
                    None
                } else if delay < Duration::from_secs(3600) {
                    Some(Instant::now() + delay)
                } else {
                    None
                };
                // whichever comes first: egui's repaint or an engine tick
                self.next = match (egui_next, w.stages.next()) {
                    (Some(a), Some(b)) => Some(a.min(b)),
                    (a, b) => a.or(b),
                };
            }
            _ => {}
        }
    }

    fn about_to_wait(&mut self, el: &ActiveEventLoop) {
        match self.next {
            Some(t) if t <= Instant::now() => {
                self.next = None;
                if let Some(w) = &self.win {
                    w.window.request_redraw();
                }
                el.set_control_flow(ControlFlow::Wait);
            }
            Some(t) => el.set_control_flow(ControlFlow::WaitUntil(t)),
            None => el.set_control_flow(ControlFlow::Wait),
        }
    }
}

/// `--snapshot`: the app drawn offscreen for a while, then written as a PNG.
fn snapshot(args: &[String]) {
    let arg = |name: &str| args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned();
    let path = arg("--snapshot").expect("--snapshot PATH");
    let (w, h) = arg("--size")
        .and_then(|s| s.split_once('x').and_then(|(a, b)| Some((a.parse::<u32>().ok()?, b.parse::<u32>().ok()?))))
        .unwrap_or((1280, 800));
    let secs: f32 = arg("--secs").and_then(|s| s.parse().ok()).unwrap_or(6.0);
    let clicks: Vec<(f32, f32)> = args
        .windows(2)
        .filter(|p| p[0] == "--click")
        .filter_map(|p| p[1].split_once(',').and_then(|(x, y)| Some((x.parse().ok()?, y.parse().ok()?))))
        .collect();
    let ppp: f32 = arg("--scale").and_then(|s| s.parse().ok()).unwrap_or(1.0);
    // typed (then Enter) a second after the last click
    let typed = arg("--type");
    let mut typed_done = typed.is_none();

    let inst = instance(None);
    let gpu = open_gpu(&inst, None).expect("gpu");
    let format = wgpu::TextureFormat::Rgba8Unorm;
    let mut renderer = egui_wgpu::Renderer::new(&gpu.device, format, egui_wgpu::RendererOptions::default());
    let egui = egui::Context::default();
    theme::setup(&egui);
    let wake: state::Wake = Arc::new(|| {});
    let mut st = State::new(egui.clone(), wake);
    let mut view = ui::View::default();
    let mut stages = stage::Stages::new(&gpu.device, &gpu.queue);
    let start = Instant::now();
    let screen_rect = egui::Rect::from_min_size(egui::Pos2::ZERO, egui::vec2(w as f32 / ppp, h as f32 / ppp));
    let mut clicked = 0usize;
    // clicks (and typing) a second apart, leaving two seconds after for answers
    let load = secs - clicks.len() as f32 - if arg("--type").is_some() { 3.0 } else { 0.0 };
    let mut last: Option<egui::FullOutput>;
    loop {
        let t = start.elapsed().as_secs_f32();
        let mut events = Vec::new();
        // the pointer waits over the next click, so it's hovering when it lands
        if let Some(&(x, y)) = clicks.get(clicked) {
            events.push(egui::Event::PointerMoved(egui::pos2(x, y)));
        }
        if clicked < clicks.len() && t > load.max(0.5) + clicked as f32 {
            let (x, y) = clicks[clicked];
            let pos = egui::pos2(x, y);
            events.push(egui::Event::PointerMoved(pos));
            events.push(egui::Event::PointerButton { pos, button: egui::PointerButton::Primary, pressed: true, modifiers: Default::default() });
            events.push(egui::Event::PointerButton { pos, button: egui::PointerButton::Primary, pressed: false, modifiers: Default::default() });
            clicked += 1;
        } else if !typed_done && clicked == clicks.len() && t > load.max(0.5) + clicked as f32 {
            let text = typed.clone().unwrap_or_default();
            events.push(egui::Event::Text(text));
            events.push(egui::Event::Key { key: egui::Key::Enter, physical_key: None, pressed: true, repeat: false, modifiers: Default::default() });
            typed_done = true;
        }
        let mut raw = egui::RawInput { screen_rect: Some(screen_rect), time: Some(t as f64), events, ..Default::default() };
        raw.viewports.entry(egui::ViewportId::ROOT).or_default().native_pixels_per_point = Some(ppp);
        let mut out = run_ui(&egui, raw, &mut st, &mut view);
        stages.update(&mut st, &mut renderer, ppp);
        for (id, deltas) in &out.textures_delta.set {
            for delta in deltas {
                renderer.update_texture(&gpu.device, &gpu.queue, *id, delta);
            }
        }
        for id in &out.textures_delta.free {
            renderer.free_texture(id);
        }
        out.textures_delta.clear();
        last = Some(out);
        if t > secs {
            break;
        }
        std::thread::sleep(Duration::from_millis(33));
    }
    let out = last.expect("a frame");
    let jobs = egui.tessellate(out.shapes, out.pixels_per_point);
    let tex = gpu.device.create_texture(&wgpu::TextureDescriptor {
        label: Some("snapshot"),
        size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
        view_formats: &[],
    });
    let view_t = tex.create_view(&Default::default());
    let screen = egui_wgpu::ScreenDescriptor { size_in_pixels: [w, h], pixels_per_point: out.pixels_per_point };
    draw_egui(&mut renderer, &gpu, &view_t, &jobs, &screen);
    // read it back
    let row = (w * 4).div_ceil(256) * 256;
    let buf = gpu.device.create_buffer(&wgpu::BufferDescriptor {
        label: None,
        size: (row * h) as u64,
        usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
        mapped_at_creation: false,
    });
    let mut enc = gpu.device.create_command_encoder(&Default::default());
    enc.copy_texture_to_buffer(
        tex.as_image_copy(),
        wgpu::TexelCopyBufferInfo {
            buffer: &buf,
            layout: wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(row), rows_per_image: Some(h) },
        },
        wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
    );
    gpu.queue.submit([enc.finish()]);
    buf.slice(..).map_async(wgpu::MapMode::Read, |_| {});
    let _ = gpu.device.poll(wgpu::PollType::wait_indefinitely());
    let data = buf.slice(..).get_mapped_range().expect("mapped");
    let mut px = Vec::with_capacity((w * h * 4) as usize);
    for y in 0..h {
        let s = (y * row) as usize;
        px.extend_from_slice(&data[s..s + (w * 4) as usize]);
    }
    drop(data);
    let img = image::RgbaImage::from_raw(w, h, px).expect("pixels");
    img.save(&path).expect("write png");
    println!("sosh: wrote {path}");
    std::process::exit(0);
}

fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("warn")).init();
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--snapshot") {
        snapshot(&args);
        return;
    }
    let el = EventLoop::<()>::with_user_event().build().expect("event loop");
    let mut app = App { proxy: el.create_proxy(), win: None, next: None };
    el.run_app(&mut app).expect("event loop");
}
