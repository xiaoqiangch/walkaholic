/* 步谜 · 疆域与爵位（纯函数，三端共用契约）
 *
 * 概念：
 * - 每个「成功开盒」的真实地点 = 一个已占领的点（需要真实坐标）
 * - 这些点的**凸包面积** = 用户的「疆域」
 * - 疆域面积决定爵位（中国古代五等爵 + 扩展）
 *
 * 为什么用凸包：用户要「围起来的最大面积」，凸包正是能包住所有点的最小凸多边形，
 * 也就是他能围出的最大面积。不是一个点一个点算，而是整体版图。
 *
 * 重要：内置演示地点没有真实坐标 → 不计入疆域。只用 curated/osm/wiki/amap/baidu 这些真实来源。
 */
(function (root) {
  'use strict';

  /* ============================================================
     1. 中国古代爵位体系
     - 周代五等爵：公、侯、伯、子、男（公爵最高）
     - 之下设「士」，之上设「王」（加分项，需极大疆域）
     每个爵位有面积门槛（平方公里）与色值、印章字
     ============================================================ */
  // minPoints：该爵位要求疆域内**至少有多少个探索点**。
  // 为什么需要：否则在远处「打四个角」就能用 4 个点围出几十平方公里。
  // 数值怎么来的：用诚实玩家行为模型（5 种画像 × 400 样本/种）跑蒙特卡洛，
  //   取「达到该面积门槛的诚实玩家的点位数 p5」，再向下取整到友好数字。
  //   代价：偶尔散步型玩家有 13.8% 会在高爵位被打回（合理，他们确实没探索那么大）。
  //   收益：4 点围 30km 半径（1163 km²）从「王」直接降到「士」。
  // 详细推演见 docs/territory.md「点数门槛」一节。
  var RANKS = [
    { key: 'commoner', order: 0, title: '白身',   seal: '民', thresholdKm2: 0,      minPoints: 0,  color: '#9CA3AF', desc: '还没有自己的疆域' },
    { key: 'shi',      order: 1, title: '士',     seal: '士', thresholdKm2: 0.05,   minPoints: 3,  color: '#64748B', desc: '初立门户，方寸之地' },
    { key: 'nan',      order: 2, title: '男爵',   seal: '男', thresholdKm2: 0.3,    minPoints: 5,  color: '#0EA5E9', desc: '一街一巷，始有封地' },
    { key: 'zi',       order: 3, title: '子爵',   seal: '子', thresholdKm2: 1.2,    minPoints: 7,  color: '#14B8A6', desc: '数坊之间，渐成版图' },
    { key: 'bo',       order: 4, title: '伯爵',   seal: '伯', thresholdKm2: 4,      minPoints: 9,  color: '#5B6CFF', desc: '半城风物，已在掌中' },
    { key: 'hou',      order: 5, title: '侯爵',   seal: '侯', thresholdKm2: 12,     minPoints: 12, color: '#8B5CF6', desc: '纵横十余里，一方之望' },
    { key: 'gong',     order: 6, title: '公爵',   seal: '公', thresholdKm2: 30,     minPoints: 15, color: '#F59E0B', desc: '半壁城池，位极人臣' },
    { key: 'wang',     order: 7, title: '王',     seal: '王', thresholdKm2: 80,     minPoints: 21, color: '#EF4444', desc: '一城之主，疆域无出其右' }
  ];

  /* ============================================================
     2. 几何：凸包 + 多边形面积
     ============================================================ */

  /** 把经纬度投影到本地平面（米）。以所有点的平均纬度做等距圆柱近似，城市尺度足够准 */
  function projectMeters(points) {
    var list = points || [];
    if (!list.length) return [];
    var sumLat = 0;
    for (var i = 0; i < list.length; i += 1) sumLat += list[i].lat;
    var meanLat = sumLat / list.length;
    var kx = Math.cos(meanLat * Math.PI / 180) * 111320;
    var ky = 110540;
    var origin = list[0];
    return list.map(function (p) {
      return { x: (p.lon - origin.lon) * kx, y: (p.lat - origin.lat) * ky };
    });
  }

  /** Andrew 单调链求凸包；返回逆时针点序 */
  function convexHull(flatPoints) {
    var pts = flatPoints.slice().sort(function (a, b) {
      if (a.x === b.x) return a.y - b.y;
      return a.x - b.x;
    });
    // 去重
    var uniq = [];
    for (var i = 0; i < pts.length; i += 1) {
      if (i === 0 || pts[i].x !== pts[i - 1].x || pts[i].y !== pts[i - 1].y) uniq.push(pts[i]);
    }
    if (uniq.length <= 2) return uniq;

    // 叉积容差（单位 m²）：小于它视为共线，避免浮点误差留下退化的细长三角
    var COLLINEAR_EPS = 0.5;
    function cross(o, a, b) {
      return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
    }
    function turnLeft(o, a, b) {
      return cross(o, a, b) > COLLINEAR_EPS;
    }
    var lower = [];
    for (var j = 0; j < uniq.length; j += 1) {
      while (lower.length >= 2 && !turnLeft(lower[lower.length - 2], lower[lower.length - 1], uniq[j])) lower.pop();
      lower.push(uniq[j]);
    }
    var upper = [];
    for (var k = uniq.length - 1; k >= 0; k -= 1) {
      while (upper.length >= 2 && !turnLeft(upper[upper.length - 2], upper[upper.length - 1], uniq[k])) upper.pop();
      upper.push(uniq[k]);
    }
    lower.pop();
    upper.pop();
    return lower.concat(upper);
  }

  /** 鞋带公式求多边形面积（平方米） */
  function polygonAreaM2(hull) {
    if (!hull || hull.length < 3) return 0;
    var sum = 0;
    for (var i = 0; i < hull.length; i += 1) {
      var a = hull[i];
      var b = hull[(i + 1) % hull.length];
      sum += a.x * b.y - b.x * a.y;
    }
    return Math.abs(sum) / 2;
  }

  /* ============================================================
     3. 疆域计算
     ============================================================ */

  /**
   * 由已占领的真实坐标点计算疆域
   * @param {Array<{lat:number, lon:number}>} points 已开盒地点的真实坐标
   * @returns {{ pointCount, hull, hullPointCount, areaKm2, areaM2, spanM }}
   */
  function territoryOf(points) {
    var valid = (points || []).filter(function (p) {
      return p && typeof p.lat === 'number' && typeof p.lon === 'number' &&
        isFinite(p.lat) && isFinite(p.lon) &&
        Math.abs(p.lat) <= 90 && Math.abs(p.lon) <= 180;
    });
    if (valid.length < 3) {
      return {
        pointCount: valid.length,
        hull: [],
        hullPointCount: 0,
        areaM2: 0,
        areaKm2: 0,
        spanM: 0
      };
    }
    var flat = projectMeters(valid);
    var hull = convexHull(flat);
    var areaM2 = polygonAreaM2(hull);
    // 最长跨度：凸包上任意两点最大距离（近似：取凸包顶点两两距离）
    var spanM = 0;
    for (var i = 0; i < hull.length; i += 1) {
      for (var j = i + 1; j < hull.length; j += 1) {
        var dx = hull[i].x - hull[j].x;
        var dy = hull[i].y - hull[j].y;
        var d = Math.sqrt(dx * dx + dy * dy);
        if (d > spanM) spanM = d;
      }
    }
    return {
      pointCount: valid.length,
      hull: hull,
      hullPointCount: hull.length,
      areaM2: areaM2,
      areaKm2: areaM2 / 1000000,
      spanM: spanM
    };
  }

  /* ============================================================
     4. 爵位判定 + 进度
     ============================================================ */

  /**
   * 爵位判定
   * @param {number} areaKm2 疆域面积
   * @param {number} [pointCount] 疆域内的探索点数；不传则只按面积算（兼容旧调用）
   */
  function rankFor(areaKm2, pointCount) {
    var area = typeof areaKm2 === 'number' && isFinite(areaKm2) ? Math.max(0, areaKm2) : 0;
    var points = typeof pointCount === 'number' && isFinite(pointCount) ? Math.max(0, pointCount) : null;

    // 1) 面积够格的最高一档
    var areaRank = RANKS[0];
    for (var i = 0; i < RANKS.length; i += 1) {
      if (area >= RANKS[i].thresholdKm2) areaRank = RANKS[i];
    }

    // 2) 扣除点数门槛：从面积档往下找第一个点数也够的
    var current = RANKS[0];
    if (points === null) {
      current = areaRank;
    } else {
      for (var k = areaRank.order; k >= 0; k -= 1) {
        if (points >= RANKS[k].minPoints) { current = RANKS[k]; break; }
      }
    }

    // 3) 目标档：
    //    - 若是被点数卡住 → 目标就是被卡的那一档（提示"再探索 N 个点"）
    //    - 否则 → 面积上的下一档（提示"再扩 X km²"）
    var blockedBy = (areaRank.order > current.order) ? areaRank : null;
    var next = null;
    if (blockedBy) {
      next = blockedBy;
    } else if (current.order + 1 < RANKS.length) {
      next = RANKS[current.order + 1];
    }

    var progress = 1;
    var toNextKm2 = 0;
    var pointsNeeded = 0;
    if (next) {
      if (blockedBy) {
        // 被点数卡住：进度按点数算
        var span = Math.max(1, next.minPoints - current.minPoints);
        progress = Math.min(1, Math.max(0, (points - current.minPoints) / span));
        pointsNeeded = Math.max(0, next.minPoints - points);
        toNextKm2 = 0;
      } else {
        var spanKm = next.thresholdKm2 - current.thresholdKm2;
        progress = spanKm > 0 ? Math.min(1, Math.max(0, (area - current.thresholdKm2) / spanKm)) : 1;
        toNextKm2 = Math.max(0, next.thresholdKm2 - area);
        pointsNeeded = points !== null ? Math.max(0, next.minPoints - points) : 0;
      }
    }

    return {
      rank: current,
      next: next,
      progress: progress,
      toNextKm2: toNextKm2,
      areaKm2: area,
      pointCount: points,
      blockedBy: blockedBy,
      pointsNeeded: pointsNeeded,
      /** 是否因为探索点太少被降级 */
      capped: !!blockedBy
    };
  }

  /** 面积格式化：< 0.01 km² 用平方米，其他用 km² */
  function formatArea(areaKm2) {
    var a = typeof areaKm2 === 'number' && isFinite(areaKm2) ? areaKm2 : 0;
    if (a <= 0) return '0 m²';
    if (a < 0.01) return Math.round(a * 1000000) + ' m²';
    if (a < 100) return a.toFixed(a < 1 ? 2 : 1) + ' km²';
    return Math.round(a) + ' km²';
  }

  /** 封号：用所在地给爵位加一个地名前缀，比如「金陵 · 子爵」 */
  function fiefTitle(rank, placeName) {
    if (!placeName) return rank.title;
    return placeName + ' · ' + rank.title;
  }

  var api = {
    RANKS: RANKS,
    territoryOf: territoryOf,
    convexHull: convexHull,
    polygonAreaM2: polygonAreaM2,
    projectMeters: projectMeters,
    rankFor: rankFor,
    formatArea: formatArea,
    fiefTitle: fiefTitle
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (root) root.BW_TERRITORY = api;
})(typeof window !== 'undefined' ? window : (typeof global !== 'undefined' ? global : this));
