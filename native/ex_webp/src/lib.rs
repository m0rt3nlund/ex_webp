use rustler::types::tuple::make_tuple;
use rustler::{Binary, Decoder, Encoder, Env, NifMap, NifResult, OwnedBinary, Term};
mod shared;
use crate::shared::{PixelLayout, WebPImage, WebPMemory};
use image::DynamicImage::{self, ImageRgba8};
use image::{imageops, EncodableLayout};
use libwebp_sys::*;
use rustler::ErlOption;
use webp::{Decoder as WebPDecoder, Encoder as WebPEncoder};

const DEFAULT_QUALITY: f32 = 60.0;

mod atoms {
    rustler::atoms! {
        ok, error
    }
}

#[derive(NifMap, Clone, Copy)]
pub struct CropConfig {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

#[derive(NifMap)]
pub struct EncodeConfig {
    pub width: u32,
    pub height: u32,
    pub resize_percent: f32,
    pub crop: ErlOption<CropConfig>,
    pub lossless: i32,
    pub quality: Option<f32>,
}

#[rustler::nif(schedule = "DirtyCpu")]
fn _encode<'a>(env: Env<'a>, body: Binary<'a>, config: EncodeConfig) -> NifResult<Term<'a>> {
    let image: DynamicImage =
        image::load_from_memory(body.as_slice()).map_err(|e| err_str(e.to_string()))?;
    let mut encoder: WebPEncoder;

    // Check if we need to resize the image, either by percent or dimensions
    let image: DynamicImage = if !config.crop.is_none() {
        let x: u32 = config.crop.as_ref().map(|x| x.x).unwrap();
        let y: u32 = config.crop.as_ref().map(|x| x.y).unwrap();
        let width: u32 = config.crop.as_ref().map(|x| x.width).unwrap();
        let height: u32 = config.crop.as_ref().map(|x| x.height).unwrap();
        crop(&image, x, y, width, height)
    } else if config.resize_percent > 0.0 {
        resize_percent(&image, config.resize_percent)
    } else if config.width > 0 && config.height > 0 {
        resize_dimensions(&image, config.width, config.height)
    } else {
        image
    };

    let encoder: WebPEncoder =
        WebPEncoder::from_image(&image).map_err(|e| err_str(e.to_string()))?;

    let webp = encoder
        .encode_advanced(&webp_config(config.lossless, config.quality)?)
        .map_err(|e| err_str(format!("{:?}", e)))?;

    let bytes: &[u8] = webp.as_bytes();

    let mut binary: OwnedBinary = OwnedBinary::new(bytes.len())
        .ok_or_else(|| err_str("failed to allocate binary".to_string()))?;

    binary.as_mut_slice().copy_from_slice(&bytes);

    let ok = atoms::ok().encode(env);

    Ok(make_tuple(env, &[ok, binary.release(env).encode(env)]))
}

fn crop(image: &DynamicImage, x: u32, y: u32, width: u32, height: u32) -> DynamicImage {
    let x_clamped = x.clamp(0, image.width());
    let y_clamped = y.clamp(0, image.height());
    let width_clamped = width.clamp(0, image.width());
    let height_clamped = height.clamp(0, image.height());
    let sub_image = imageops::crop_imm(image, x_clamped, y_clamped, width_clamped, height_clamped);
    let cropped_image: DynamicImage = ImageRgba8(sub_image.to_image());
    return cropped_image;
}

fn resize_percent(image: &DynamicImage, percent: f32) -> DynamicImage {
    let width = ((image.width() as f32) * percent / 100.0).round() as u32;
    let height = ((image.height() as f32) * percent / 100.0).round() as u32;
    let resized_image: DynamicImage = ImageRgba8(imageops::thumbnail(image, width, height));

    return resized_image;
}

fn resize_dimensions(image: &DynamicImage, width: u32, height: u32) -> DynamicImage {
    let (width, height) = calc_dimension(&image, width, height);

    let resized_image: DynamicImage = ImageRgba8(imageops::thumbnail(image, width, height));
    return resized_image;
}

#[rustler::nif(schedule = "DirtyCpu")]
fn _decode<'a>(env: Env<'a>, body: Binary<'a>) -> NifResult<Term<'a>> {
    let bytes = body.as_slice();

    let features = BitstreamFeatures::new(bytes)
        .ok_or_else(|| err_str("failed to allocate binary".to_string()))?;

    if features.has_animation() {
        return Err(err_str("Animations are not supported".to_string()));
    }

    let width = features.width();
    let height = features.height();
    let pixel_count = width * height;

    let image_ptr = unsafe {
        let mut width = width as i32;
        let mut height = height as i32;

        if features.has_alpha() {
            WebPDecodeRGBA(
                body.as_ptr(),
                body.len(),
                &mut width as *mut _,
                &mut height as *mut _,
            )
        } else {
            WebPDecodeRGB(
                body.as_ptr(),
                body.len(),
                &mut width as *mut _,
                &mut height as *mut _,
            )
        }
    };

    if image_ptr.is_null() {
        return Err(err_str("No image".to_string()));
    }

    let image = if features.has_alpha() {
        let len = 4 * pixel_count as usize;

        WebPImage::new(WebPMemory(image_ptr, len), PixelLayout::Rgba, width, height)
    } else {
        let len = 3 * pixel_count as usize;

        WebPImage::new(WebPMemory(image_ptr, len), PixelLayout::Rgb, width, height)
    };

    let bytes: &[u8] = image.as_bytes();

    let mut binary: OwnedBinary = OwnedBinary::new(bytes.len())
        .ok_or_else(|| err_str("failed to allocate binary".to_string()))?;

    binary.as_mut_slice().copy_from_slice(&bytes);

    let ok = atoms::ok().encode(env);

    Ok(make_tuple(env, &[ok, binary.release(env).encode(env)]))
}

fn err_str(error: String) -> rustler::Error {
    rustler::Error::Term(Box::new(error))
}

fn webp_config(lossless: i32, quality: Option<f32>) -> NifResult<WebPConfig> {
    let mut config: WebPConfig =
        WebPConfig::new().map_err(|_| err_str("failed to create WebP config".to_string()))?;

    config.lossless = lossless;
    config.method = 2;
    config.image_hint = WebPImageHint::WEBP_HINT_PICTURE;
    config.sns_strength = 70;
    config.filter_sharpness = 0;
    config.filter_strength = 25;

    if let Some(quality) = quality {
        config.quality = quality;
    } else {
        config.quality = DEFAULT_QUALITY;
    }

    Ok(config)
}

fn calc_dimension(image: &DynamicImage, width: u32, height: u32) -> (u32, u32) {
    if image.width() >= image.height() {
        // landscape
        let ratio = image.height() as f32 / image.width() as f32;
        let height = (ratio * width as f32).round() as u32;

        (width, height)
    } else {
        // portrait
        let ratio = image.width() as f32 / image.height() as f32;
        let width = (ratio * height as f32).round() as u32;

        (width, height)
    }
}

pub struct BitstreamFeatures(WebPBitstreamFeatures);

impl BitstreamFeatures {
    pub fn new(data: &[u8]) -> Option<Self> {
        unsafe {
            let mut features: WebPBitstreamFeatures = std::mem::zeroed();

            let result = WebPGetFeatures(data.as_ptr(), data.len(), &mut features as *mut _);

            if result == VP8StatusCode::VP8_STATUS_OK {
                return Some(Self(features));
            }
        }

        None
    }

    /// Returns the width of the image as described by the bitstream in pixels.
    pub fn width(&self) -> u32 {
        self.0.width as u32
    }

    /// Returns the height of the image as described by the bitstream in pixels.
    pub fn height(&self) -> u32 {
        self.0.height as u32
    }

    /// Returns true if the image as described by the bitstream has an alpha channel.
    pub fn has_alpha(&self) -> bool {
        self.0.has_alpha == 1
    }

    /// Returns true if the image as described by the bitstream is animated.
    pub fn has_animation(&self) -> bool {
        self.0.has_animation == 1
    }

    /// Returns the format of the image as described by image bitstream.
    pub fn format(&self) -> Option<BitstreamFormat> {
        match self.0.format {
            0 => Some(BitstreamFormat::Undefined),
            1 => Some(BitstreamFormat::Lossy),
            2 => Some(BitstreamFormat::Lossless),
            _ => None,
        }
    }
}

pub enum BitstreamFormat {
    Undefined = 0,
    Lossy = 1,
    Lossless = 2,
}

rustler::init!("Elixir.ExWebp", [_encode, _decode]);
