/** Normalize a whole screenshot once. Never infer polarity from a tight glyph:
 * a bold I can be almost entirely ink and would otherwise be inverted. */
export function normalizeRaster(src: Pick<ImageData, "data" | "width" | "height">) {
  const { width, height, data } = src;
  const gray = new Uint8Array(width * height);
  const histogram = new Uint32Array(256);
  for (let p = 0; p < gray.length; p++) {
    const i = p * 4;
    const alpha = data[i + 3] / 255;
    const value = Math.round((0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2]) * alpha + 255 * (1 - alpha));
    gray[p] = value;
    histogram[value]++;
  }
  let total = 0;
  for (let i = 0; i < 256; i++) total += i * histogram[i];
  let weight = 0, sum = 0, best = -1, threshold = 127;
  for (let i = 0; i < 255; i++) {
    weight += histogram[i];
    sum += i * histogram[i];
    const other = gray.length - weight;
    if (!weight || !other) continue;
    const variance = weight * other * (sum / weight - (total - sum) / other) ** 2;
    if (variance > best) { best = variance; threshold = i; }
  }
  // The screenshot border is a better background sample than the crop mean.
  let darkBorder = 0, borderCount = 0;
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      if (x !== 0 && y !== 0 && x !== width - 1 && y !== height - 1) continue;
      borderCount++;
      if (gray[y * width + x] <= threshold) darkBorder++;
    }
  }
  const inverted = darkBorder > borderCount / 2;
  const pixels = new Uint8ClampedArray(data.length);
  const tonalData = new Uint8ClampedArray(data.length);
  let darkSum = 0, darkCount = 0, lightSum = 0, lightCount = 0;
  for (let value = 0; value < 256; value++) {
    if (value <= threshold) { darkSum += value * histogram[value]; darkCount += histogram[value]; }
    else { lightSum += value * histogram[value]; lightCount += histogram[value]; }
  }
  const darkMean = darkCount ? darkSum / darkCount : 0;
  const lightMean = lightCount ? lightSum / lightCount : 255;
  for (let p = 0; p < gray.length; p++) {
    const ink = best >= 0 && (inverted ? gray[p] > threshold : gray[p] <= threshold);
    pixels[p * 4] = pixels[p * 4 + 1] = pixels[p * 4 + 2] = ink ? 0 : 255;
    pixels[p * 4 + 3] = 255;
    // Preserve antialias coverage for tracing. Binarization is for OCR only;
    // enlarging already-binary pixels would bake stair-steps into curves.
    const tone = Math.max(0, Math.min(255, (gray[p] - darkMean) / Math.max(1, lightMean - darkMean) * 255));
    const normalizedTone = best < 0 ? 255 : inverted ? 255 - tone : tone;
    tonalData[p * 4] = tonalData[p * 4 + 1] = tonalData[p * 4 + 2] = normalizedTone;
    tonalData[p * 4 + 3] = 255;
  }
  return { data: pixels, tonalData, width, height, threshold, inverted };
}

export function inkBounds(src: Pick<ImageData, "data" | "width" | "height">) {
  let x0 = src.width, y0 = src.height, x1 = -1, y1 = -1, count = 0;
  for (let y = 0; y < src.height; y++) for (let x = 0; x < src.width; x++) {
    const i = (y * src.width + x) * 4;
    if (src.data[i + 3] > 0 && src.data[i] < 128) {
      x0 = Math.min(x0, x); x1 = Math.max(x1, x);
      y0 = Math.min(y0, y); y1 = Math.max(y1, y); count++;
    }
  }
  return count ? { x0, y0, x1: x1 + 1, y1: y1 + 1, count } : null;
}
