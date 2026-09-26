import test from 'node:test';
import assert from 'node:assert/strict';
import { parseTsv } from '../desktop.mjs';
test('tesseract TSV words group into line regions with pixel rects', () => {
  const h='level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext';
  const rows=[h,'1\t1\t0\t0\t0\t0\t0\t0\t600\t160\t-1\t','5\t1\t1\t1\t1\t1\t20\t30\t80\t30\t90\tHello','5\t1\t1\t1\t1\t2\t110\t32\t100\t28\t96\tworld','5\t1\t1\t1\t2\t1\t20\t90\t60\t20\t80\tNext','5\t1\t1\t1\t2\t2\t90\t90\t10\t20\t50\t '];
  assert.deepEqual(parseTsv(rows.join('\n')),[
    {id:'line-1',text:'Hello world',rect:[20,30,190,30],granularity:'line',confidence:0.93},
    {id:'line-2',text:'Next',rect:[20,90,60,20],granularity:'line',confidence:0.8}]);
});
