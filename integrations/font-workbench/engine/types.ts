export type Step =
  | "upload"
  | "segment"
  | "label"
  | "vectorize"
  | "fill"
  | "export";

export interface GlyphCandidate {
  id: string;
  imageId: number;
  bbox: { x: number; y: number; w: number; h: number };
  bitmap: ImageData;
  char: string | null;
  confidence: number;
  lineId?: string;
  baselineY?: number;
  normalized?: boolean;
}

export interface ImageMetrics {
  baselineY: number; // pixels, in source image
  capHeightPx: number;
}

export interface VectorGlyph {
  char: string;
  path: string;
  advanceWidth: number;
  xMin: number;
  yMin: number;
  xMax: number;
  yMax: number;
  source: "traced" | "derived" | "ai" | "drawn" | "base" | "inferred" | "space";
  evidence?: string[];
  review?: string;
  sourceFont?: string;
  license?: string;
  copyright?: string;
  inkDensity?: number; // fraction of binarized crop that was ink — weight proxy
}

export interface FontMetrics {
  unitsPerEm: number;
  ascent: number;
  descent: number;
  xHeight: number;
  capHeight: number;
  baselineY: number;
}

export interface PipelineState {
  step: Step;
  sourceImage: HTMLImageElement | null;
  candidates: GlyphCandidate[];
  glyphs: Record<string, VectorGlyph>;
  metrics: FontMetrics | null;
  fontName: string;
  error: string | null;
  busy: boolean;
}

export const INITIAL_STATE: PipelineState = {
  step: "upload",
  sourceImage: null,
  candidates: [],
  glyphs: {},
  metrics: null,
  fontName: "MyFont",
  error: null,
  busy: false,
};

export const BASIC_LATIN: string[] = [
  ..."ABCDEFGHIJKLMNOPQRSTUVWXYZ",
  ..."abcdefghijklmnopqrstuvwxyz",
  ..."0123456789",
  ..."!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~ ",
];
