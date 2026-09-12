import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import opentype from 'opentype.js';
import { estimateMetrics } from '../engine/metrics';
import { alignCaptured } from '../engine/alignment';
import { transformPath, parsePath } from '../engine/paths';
import { buildFont } from '../engine/font';
import type { GlyphCandidate, VectorGlyph } from '../engine/types';

const sample = (id: string, char: string, lineId: string, x: number, y: number, h: number): GlyphCandidate =>
  ({ id, char, lineId, imageId: 0, bbox: { x, y, w: 20, h }, bitmap: {} as ImageData, confidence: 99 });

test('mixed sizes within one OCR line retain independent scales and shared baseline', () => {
  const input = [sample('large-H','H','one',0,30,70),sample('large-x','x','one',50,50,50),
    sample('small-H','H','one',200,65,35),sample('small-x','x','one',230,75,25),sample('small-g','g','one',260,75,34)];
  const {perCandidate} = estimateMetrics(input);
  assert.equal(perCandidate['large-H'].capHeightPx,70);
  assert.equal(perCandidate['small-H'].capHeightPx,35);
  assert.deepEqual(perCandidate['small-g'],perCandidate['small-H']);
  assert.equal(perCandidate['small-g'].baselineY,100);
});

test('lowercase-only text learns the font proportions from other sizes', () => {
  const {metrics,perCandidate} = estimateMetrics([sample('H','H','title',0,10,100),sample('x','x','title',80,50,60),
    sample('m','m','caption',0,200,30),sample('n','n','caption',40,200,30)]);
  assert.equal(metrics.xHeight,420);
  assert.equal(perCandidate.m.capHeightPx,50);
  assert.equal(perCandidate.n.baselineY,230);
});

const roots = [new URL('../../../src/Resources/FontWorkbench/fonts/',import.meta.url), new URL('../../../src/Resources/Fonts/',import.meta.url)];
for (const root of roots) for (const filename of readdirSync(root).filter(n => n.endsWith('.ttf'))) {
  test(`${filename}: mixed-size export keeps letter heights, baselines, tails and counters`, async () => {
    const bytes=readFileSync(new URL(filename,root));
    const font=opentype.parse(bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength) as ArrayBuffer);
    const text='HEFImnrwxzaceosbdhklgpqyO.';
    const inputs: GlyphCandidate[]=[], original = new Map<string,{char:string;size:number;baseline:number}>();
    for (const [line,size] of [17,31,68].entries()) {
      let x=0; const baseline=100+line*120;
      for (const char of text) {
        const glyph=font.charToGlyph(char), b=glyph.getBoundingBox(), scale=size/font.unitsPerEm;
        const y=Math.floor(baseline-b.y2*scale), h=Math.ceil(baseline-b.y1*scale)-y;
        const id=`${line}-${char}`;
        inputs.push(sample(id,char,String(line),x,y,h));original.set(id,{char,size,baseline});x+=glyph.advanceWidth!*scale;
      }
    }
    const {metrics,perCandidate}=estimateMetrics(inputs);
    const raw: Record<string,VectorGlyph>={};
    for (const [index,char] of [...text].entries()) {
      const id=`${index%3}-${char}`, c=original.get(id)!, m=perCandidate[id];
      const px=metrics.capHeight/m.capHeightPx;
      const path=transformPath(font.charToGlyph(char).path, c.size/font.unitsPerEm*px, c.size/font.unitsPerEm*px, 0,(m.baselineY-c.baseline)*px);
      const b=path.getBoundingBox();
      raw[char]={char,path:path.toPathData(2),advanceWidth:600,xMin:b.x1,xMax:b.x2,yMin:b.y1,yMax:b.y2,source:'traced'};
    }
    const aligned=alignCaptured(raw,metrics);
    for(const char of 'mnrwxz') {assert.ok(Math.abs(aligned[char].yMax-metrics.xHeight)<.02,char);assert.ok(Math.abs(aligned[char].yMin)<.02,char);}
    for(const char of 'HEFI') assert.ok(Math.abs(aligned[char].yMax-metrics.capHeight)<.02,char);
    for(const char of 'gpqy') assert.ok(aligned[char].yMin<0,`${char} retains descender`);
    assert.equal(aligned['.'],raw['.'],'punctuation stays at its captured position');
    assert.equal(parsePath(aligned.O.path).commands.filter(c=>c.type==='M').length,parsePath(raw.O.path).commands.filter(c=>c.type==='M').length,'counters retained');
    for(const char of text) {
      assert.equal(aligned[char].advanceWidth,raw[char].advanceWidth);
      // Compare actual horizontal outline coordinates: opentype's curve-bound
      // solver can report slightly different extrema after a vertical scaling.
      const horizontal = (g: VectorGlyph) => parsePath(g.path).commands.map(c =>
        ['x','x1','x2'].map(key => (c as unknown as Record<string,number>)[key]));
      assert.deepEqual(horizontal(aligned[char]),horizontal(raw[char]),`${char} preserves width and slant`);
    }
    const exported=opentype.parse(await buildFont(aligned,metrics,'Mixed size regression'));
    for(const char of 'mnrwxz') assert.ok(Math.abs(exported.charToGlyph(char).getBoundingBox().y2-metrics.xHeight)<=1,'actual OTF height');
  });
}
