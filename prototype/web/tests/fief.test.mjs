import test from 'node:test';
import assert from 'node:assert/strict';
import F from '../fief.js';

const RANK = {
  hou: { key: 'hou', title: '侯爵' },
  bo: { key: 'bo', title: '伯爵' },
  zi: { key: 'zi', title: '子爵' },
  nan: { key: 'nan', title: '男爵' },
  gong: { key: 'gong', title: '公爵' },
  wang: { key: 'wang', title: '王' },
  shi: { key: 'shi', title: '士' }
};
const STATS = { spanM: 2000, pointCount: 5 };

function fief(names, rankKey) {
  const points = (Array.isArray(names) ? names : [names]).map(n =>
    typeof n === 'string' ? { lat: 32.06, lon: 118.77, name: n } : n
  );
  return F.fiefNameOf(points, RANK[rankKey], STATS);
}

test('用户给的例子：幕府山 → 幕府侯，紫峰大厦 → 紫峰伯', () => {
  assert.equal(fief('南京幕府山', 'hou').title, '幕府侯');
  assert.equal(fief('紫峰大厦', 'bo').title, '紫峰伯');
});

test('通用后缀剥离正确（湖/河/寺/陵/公园/书店）', () => {
  assert.equal(fief('玄武湖', 'hou').title, '玄武侯');
  assert.equal(fief('秦淮河', 'hou').title, '秦淮侯');
  assert.equal(fief('鸡鸣寺', 'bo').title, '鸡鸣伯');
  assert.equal(fief('中山陵', 'gong').title, '中山公');
  assert.equal(fief('鼓楼公园', 'bo').title, '鼓楼伯');
  assert.equal(fief('先锋书店', 'zi').title, '先锋子');
});

test('行政区前缀只在还剩 ≥2 字时才剥离', () => {
  // 「玄武湖」剥掉「湖」剩「玄武」，不能因为「玄武」是区名就剥空
  assert.equal(F.properNameOf('玄武湖'), '玄武');
  assert.equal(F.properNameOf('秦淮河'), '秦淮');
  // 「南京幕府山」可以剥掉「南京」
  assert.equal(F.properNameOf('南京幕府山'), '幕府');
});

test('绝不编造：取不到地名时只给爵位，不硬凑', () => {
  for (const name of ['人民公园', '3号楼', 'A座', '上海博物馆', '南京博物院']) {
    const r = fief(name, 'bo');
    assert.equal(r.fief, '', `${name} 不应产出采邑名`);
    assert.equal(r.title, '伯爵', `${name} 应只显示爵位`);
  }
});

test('城市名不用于低阶封邑（避免「上海伯」）', () => {
  const r = fief('上海博物馆', 'bo');
  assert.equal(r.fief, '', '城市名已被过滤，且无其他候选');
  assert.ok(!r.title.includes('上海'), '不应出现城市名');
});

test('避免与爵位后缀叠字（夫子+子 → 不产出夫子子）', () => {
  const r = fief('夫子庙', 'zi');
  assert.notEqual(r.title, '夫子子', '不能出现叠字封号');
});

test('王/公级用城市古称', () => {
  // 地点名里含「南京」→ 金陵
  const r = fief('南京幕府山', 'wang');
  assert.equal(r.title, '金陵王');
  assert.equal(r.basis.includes('金陵'), true);
});

test('侯级跨城 → 以治所取大区古称（汉制「以治所为号」）', () => {
  // 南京×2 + 苏州×1 → 治所在南京（江苏）→ 江东
  const r = fief(['南京幕府山', '南京玄武湖', '苏州拙政园'], 'hou');
  assert.equal(r.title, '江东侯');
  assert.ok(r.basis.includes('治所'), '命名依据应说明治所');
});

test('识别不出城市时，退回地点专名而不是硬编大区', () => {
  const points = [
    { lat: 32.06, lon: 118.77, name: '王家村古井' },
    { lat: 33.10, lon: 119.20, name: '李家渡口' }
  ];
  const r = F.fiefNameOf(points, RANK.hou, STATS);
  // 不认识城市 → 无法判断是否跨城 → 用地点专名（真实来源，不编造）
  assert.equal(r.cities.length, 0, '不应凭空识别出城市');
  assert.ok(r.fief.length > 0 || r.title === '侯爵', `实际 ${r.title}`);
  assert.ok(!r.title.includes('关内') || r.basis.includes('跨'), '关内侯只在确实跨城时用');
});

test('王级跨城 → 大区古称', () => {
  const r = fief(['南京幕府山', '苏州拙政园'], 'wang');
  assert.ok(r.fief.length > 0, '跨城王级应有采邑名');
});

test('同名出现次数多的优先（更有代表性）', () => {
  const r = fief(['幕府山', '幕府山', '鸡鸣寺'], 'hou');
  assert.equal(r.fief, '幕府');
});

test('空输入 / 白身不封号', () => {
  assert.equal(F.fiefNameOf([], RANK.hou, STATS).fief, '');
  assert.equal(F.fiefNameOf([], RANK.shi, STATS).fief, '');
});

test('专名长度 2–4 字', () => {
  for (const name of ['幕府山', '紫峰大厦', '颐和路公馆区', '燕子矶', '老门东', '新街口']) {
    const proper = F.properNameOf(name);
    if (proper) {
      assert.ok(proper.length >= 2 && proper.length <= 4, `${name} → ${proper} 长度不符`);
    }
  }
});

test('带括号/连字符的名字能被清洗', () => {
  assert.equal(F.properNameOf('幕府山（幕燕风景区）'), '幕府');
  assert.equal(F.properNameOf('紫峰·绿地中心'), '紫峰');
});

test('古称映射表覆盖主要城市', () => {
  assert.equal(F.ancientNameOf('南京'), '金陵');
  assert.equal(F.ancientNameOf('杭州'), '临安');
  assert.equal(F.ancientNameOf('西安'), '长安');
  assert.equal(F.ancientNameOf('成都'), '锦官');
  assert.equal(F.ancientNameOf('不存在'), '');
});

test('大区映射', () => {
  assert.equal(F.regionNameOf('山东省某地'), '胶东');
  assert.equal(F.regionNameOf('四川省某地'), '巴蜀');
  assert.equal(F.regionNameOf(''), '');
});

test('爵位后缀表与爵位体系一致', () => {
  assert.equal(F.RANK_SUFFIX.hou, '侯');
  assert.equal(F.RANK_SUFFIX.bo, '伯');
  assert.equal(F.RANK_SUFFIX.zi, '子');
  assert.equal(F.RANK_SUFFIX.nan, '男');
  assert.equal(F.RANK_SUFFIX.gong, '公');
  assert.equal(F.RANK_SUFFIX.wang, '王');
  assert.equal(F.RANK_SUFFIX.commoner, '');
});
