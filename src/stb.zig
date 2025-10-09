const c = @cImport({
    @cInclude("stb_image.h");
    @cInclude("stb_image_write.h");
});

pub const load_from_memory = c.stbi_load_from_memory;
pub const load = c.stbi_load;
pub const image_free = c.stbi_image_free;
pub const write_png = c.stbi_write_png;
pub const write_png_to_mem = c.stbi_write_png_to_mem;
