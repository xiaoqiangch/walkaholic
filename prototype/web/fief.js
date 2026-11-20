/* 步谜 · 采邑封号（疆域冠名）
 *
 * ============ 制度依据 ============
 * 《周礼·春官·大宗伯》：公、侯、伯、子、男五等，各有封疆。
 * 《汉书·地理志》：王国以郡为国名（胶东、胶西、淄川、济南…），侯国以县为食邑。
 * 《后汉书·百官志》：列侯「功大者食县，小者食乡、亭」。
 * 唐代：亲王、郡王以州郡名（汾阳王、太原王），国公以国名（赵国公）。
 * 秦汉二十等爵：第十九级「关内侯」，有爵无国，泛称「关内」。
 *
 * ============ 现代适配规则 ============
 * 封号 = 采邑名 + 爵位。例：幕府侯、紫峰伯、胶东王。
 *
 * 一、爵位后缀由疆域面积决定（见 RANKS，与爵位系统共用）。
 * 二、采邑名取自用户疆域内**真实地点**的专名：
 *     1) 剥离行政区前缀（南京、鼓楼区、玄武区…）
 *     2) 剥离通用后缀（博物馆、步行街、大厦、公园、故居、遗址…）
 *     3) 保留 1–3 字专名；空或过泛则换下一个候选，全部失败则不冠名
 * 三、地名粒度随爵位升高而变粗，但不硬拔高：
 *     王 → 城市古称（南京→金陵、杭州→临安）；无古称则用城市名
 *     公/侯/伯/子/男 → 领地内地点的专名
 * 四、跨城疆域：
 *     王 → 「{大区}王」用所在省/城市古称
 *     侯 → 特例「关内侯」（历史真实爵位，表跨越关塞的大片封地）
 * 五、**绝不编造**：取不到合格地名时，只显示爵位（如「侯爵」），不硬凑。
 */
(function (root) {
  'use strict';

  /* ---------- 1. 城市古称（《读史方舆纪要》《元和郡县志》所载常用别称） ---------- */
  var CITY_ALIASES = {
    '南京': ['金陵', '建康', '应天'],
    '北京': ['燕京', '北平', '幽州'],
    '上海': ['申城', '华亭'],
    '杭州': ['临安', '钱塘'],
    '西安': ['长安', '京兆'],
    '洛阳': ['洛邑', '东都'],
    '开封': ['汴梁', '东京'],
    '苏州': ['姑苏', '吴门'],
    '成都': ['锦官', '蓉城'],
    '广州': ['番禺', '羊城'],
    '武汉': ['江城', '江夏'],
    '扬州': ['广陵', '江都'],
    '绍兴': ['会稽', '越州'],
    '福州': ['三山', '榕城'],
    '济南': ['历下', '齐州'],
    '青岛': ['胶澳', '琴岛'],
    '厦门': ['鹭岛', '思明'],
    '长沙': ['潭州', '星城'],
    '南昌': ['洪州', '豫章'],
    '合肥': ['庐州', '庐阳'],
    '太原': ['并州', '晋阳'],
    '郑州': ['圃田', '荥阳'],
    '沈阳': ['盛京', '奉天'],
    '重庆': ['渝州', '巴县'],
    '保定': ['上谷', '保阳'],
    '徐州': ['彭城', '涿鹿'],
    '镇江': ['京口', '润州'],
    '常州': ['毗陵', '晋陵'],
    '无锡': ['梁溪', '金匮'],
    '宁波': ['明州', '鄞县'],
    '温州': ['永嘉', '瓯越'],
    '桂林': ['始安', '静江'],
    '昆明': ['拓东', '鄯阐'],
    '贵阳': ['筑城', '贵筑'],
    '兰州': ['金城', '皋兰'],
    '银川': ['兴庆', '灵州'],
    '西宁': ['湟中', '青唐'],
    '乌鲁木齐': ['迪化', '轮台'],
    '拉萨': ['逻些', '惹萨'],
    '石家庄': ['真定', '常山'],
    '天津': ['直沽', '津门'],
    '青岛': ['胶澳', '琴岛']
  };

  /* ---------- 1b. 城市 → 省份（跨城王级据此取大区古称） ---------- */
  var CITY_PROVINCE = {
    '南京': '江苏', '苏州': '江苏', '无锡': '江苏', '常州': '江苏', '镇江': '江苏',
    '扬州': '江苏', '徐州': '江苏', '南通': '江苏', '盐城': '江苏', '泰州': '江苏',
    '杭州': '浙江', '宁波': '浙江', '温州': '浙江', '绍兴': '浙江', '嘉兴': '浙江',
    '金华': '浙江', '台州': '浙江', '湖州': '浙江',
    '上海': '上海', '北京': '北京', '天津': '天津', '重庆': '重庆',
    '广州': '广东', '深圳': '广东', '珠海': '广东', '佛山': '广东', '东莞': '广东',
    '西安': '陕西', '太原': '山西', '石家庄': '河北', '济南': '山东', '青岛': '山东',
    '郑州': '河南', '洛阳': '河南', '开封': '河南', '武汉': '湖北', '长沙': '湖南',
    '成都': '四川', '昆明': '云南', '贵阳': '贵州', '南宁': '广西', '桂林': '广西',
    '福州': '福建', '厦门': '福建', '泉州': '福建', '南昌': '江西', '合肥': '安徽',
    '沈阳': '辽宁', '大连': '辽宁', '长春': '吉林', '哈尔滨': '黑龙江',
    '兰州': '甘肃', '西宁': '青海', '银川': '宁夏', '乌鲁木齐': '新疆', '拉萨': '西藏',
    '呼和浩特': '内蒙古', '海口': '海南'
  };

  /* ---------- 2. 大区（王级跨城时用） ---------- */
  var REGION_NAMES = {
    '山东': '胶东', '江苏': '江东', '浙江': '会稽', '广东': '岭南',
    '广西': '岭南', '福建': '闽海', '湖南': '湘中', '湖北': '荆楚',
    '四川': '巴蜀', '陕西': '关中', '山西': '河东', '河北': '燕赵',
    '河南': '中原', '安徽': '江淮', '江西': '豫章', '云南': '南中',
    '贵州': '黔中', '甘肃': '陇右', '辽宁': '辽东', '吉林': '松漠',
    '黑龙江': '黑水', '内蒙古': '漠南', '新疆': '西域', '宁夏': '朔方',
    '青海': '河湟', '西藏': '吐蕃', '海南': '琼崖'
  };

  /* ---------- 3. 剥离规则 ---------- */
  // 行政区前缀（按长度降序，长的先剥）
  var ADMIN_PREFIXES = [
    '内蒙古自治区', '广西壮族自治区', '宁夏回族自治区', '新疆维吾尔自治区', '西藏自治区',
    '北京市', '上海市', '天津市', '重庆市',
    '南京', '北京', '上海', '广州', '深圳', '杭州', '成都', '武汉', '西安', '苏州',
    '天津', '重庆', '长沙', '郑州', '青岛', '济南', '沈阳', '大连', '厦门', '福州',
    '合肥', '南昌', '太原', '兰州', '昆明', '贵阳', '南宁', '海口', '银川', '西宁',
    '乌鲁木齐', '拉萨', '呼和浩特', '石家庄', '哈尔滨', '长春', '无锡', '常州', '镇江',
    '扬州', '徐州', '温州', '绍兴', '嘉兴', '金华', '台州', '珠海', '佛山', '东莞',
    '鼓楼区', '玄武区', '秦淮区', '建邺区', '栖霞区', '雨花台区', '江宁区', '浦口区',
    '六合区', '溧水区', '高淳区', '静安区', '黄浦区', '徐汇区', '长宁区', '普陀区',
    '虹口区', '杨浦区', '闵行区', '宝山区', '嘉定区', '浦东新区', '金山区', '松江区',
    '青浦区', '奉贤区', '崇明区', '东城区', '西城区', '朝阳区', '丰台区', '石景山区',
    '海淀区', '门头沟区', '房山区', '通州区', '顺义区', '昌平区', '大兴区', '怀柔区',
    '鼓楼', '玄武', '秦淮', '建邺', '栖霞', '雨花台', '江宁', '浦口', '静安', '黄浦',
    '徐汇', '长宁', '普陀', '虹口', '杨浦', '闵行', '宝山', '嘉定', '浦东', '金山',
    '松江', '青浦', '奉贤', '崇明', '东城', '西城', '朝阳', '丰台', '石景山', '海淀',
    '门头沟', '房山', '通州', '顺义', '昌平', '大兴', '怀柔'
  ];

  // 通用后缀（按长度降序）
  var GENERIC_SUFFIXES = [
    '国家级自然保护区', '省级文物保护单位', '全国重点文物保护单位', '历史文化街区',
    '生活文化中心', '商业综合体', '文化艺术中心', '体育文化公园',
    '步行街', '商业街', '小吃街', '美食街',
    '博物院', '博物馆', '纪念馆', '美术馆', '图书馆', '展览馆', '文化馆', '艺术馆',
    '研究院', '大剧院', '剧院', '音乐厅', '电影院', '体育馆', '体育场',
    '大厦', '大楼', '广场', '公园', '花园', '游园', '植物园', '动物园',
    '故居', '旧址', '会址', '遗址', '遗迹', '纪念地',
    '大学', '学院', '学校', '中学', '小学', '校区',
    '寺', '庙', '宫', '观', '庵', '祠', '堂', '教堂',
    '塔', '楼', '阁', '亭', '台', '桥', '闸', '码头', '渡口',
    '街', '路', '道', '巷', '里', '弄', '坊', '胡同', '大道',
    '园', '馆', '站', '城', '区', '镇', '村', '山', '湖', '河', '江',
    '中心', '总店', '分店', '旗舰店', '专卖店',
    '旧址纪念馆', '纪念堂', '旅游景区', '风景区', '旅游区', '公馆区', '公馆',
    '书店', '书吧', '咖啡馆', '咖啡店', '茶馆', '茶舍', '酒吧', '酒馆',
    '餐厅', '饭店', '饭馆', '客栈', '旅社', '民宿', '食堂', '面馆',
    '陵', '寝', '墓', '坛', '庙', '祠', '关', '门', '渡', '苑', '圃',
    '榭', '轩', '斋', '居', '庐', '舍', '屋', '宅', '府', '第', '墅',
    '溪', '涧', '泉', '井', '潭', '池', '塘', '湾', '浦', '洲', '屿', '崖', '峪', '岗', '岭', '峰'
  ];

  /** 返回列表里能匹配文本开头的最长项 */
  function longestPrefixMatch(text, list) {
    var best = null;
    for (var i = 0; i < list.length; i += 1) {
      var token = list[i];
      if (text.length > token.length && text.indexOf(token) === 0) {
        if (!best || token.length > best.length) best = token;
      }
    }
    return best;
  }

  /** 返回列表里能匹配文本结尾的最长项 */
  function longestSuffixMatch(text, list) {
    var best = null;
    for (var i = 0; i < list.length; i += 1) {
      var token = list[i];
      if (text.length > token.length && text.slice(-token.length) === token) {
        if (!best || token.length > best.length) best = token;
      }
    }
    return best;
  }

  function stripOne(text, list) {
    for (var i = 0; i < list.length; i += 1) {
      var token = list[i];
      if (text.length >= token.length && text.indexOf(token) === 0) {
        return text.slice(token.length);
      }
    }
    return null;
  }

  function stripSuffixOne(text, list) {
    for (var i = 0; i < list.length; i += 1) {
      var token = list[i];
      if (text.length >= token.length && text.slice(-token.length) === token) {
        return text.slice(0, text.length - token.length);
      }
    }
    return null;
  }

  // 不能当地名的泛词（出现在很多地方，没有"采邑"意味）
  var GENERIC_STEMS = [
    '人民', '博物', '文化', '艺术', '商业', '中心', '体育', '休闲', '生活', '购物',
    '国际', '世纪', '现代', '中央', '城市', '市民', '群众', '工人', '劳动', '青年',
    '少年', '儿童', '妇幼', '老年', '第一', '第二', '第三', '大', '小', '新', '老',
    '东', '西', '南', '北', '中', '上', '下', '前', '后', '左', '右',
    '小区', '社区', '街道', '路口', '车站', '医院', '学校', '超市', '商场', '酒店'
  ];

  /** 从地点名提取专名；返回 '' 表示提不出来（不硬凑） */
  function properNameOf(rawName) {
    if (!rawName || typeof rawName !== 'string') return '';
    var name = rawName.trim();
    if (!name) return '';

    // 括号内容丢掉（「某某（旧址）」这类）
    name = name.replace(/[（(【\[].*?[）)】\]]/g, '').trim();
    // 去掉「·」之后的分店名（连锁店名不当地名）
    name = name.split(/[·•]/)[0].trim();

    // 关键：**只剥一个最长后缀**，且不再循环。
    // 循环剥会把「南京幕府山」→ 幕府 → 幕（「府」也是后缀）这种越剥越短。
    var suffix = longestSuffixMatch(name, GENERIC_SUFFIXES);
    if (suffix) {
      var trimmed = name.slice(0, name.length - suffix.length);
      // 剥完只剩 1 字（「紫峰」剥「峰」→「紫」）就不剥了，1 字不成采邑名
      if (trimmed.length >= 2) name = trimmed;
    }

    // 只剥一个最长行政区前缀，且剥完必须还剩 >= 2 字
    // 「玄武湖」剥掉「湖」剩「玄武」，再剥行政区就空了 —— 玄武是湖名本身，不能被剥
    var prefix = longestPrefixMatch(name, ADMIN_PREFIXES);
    if (prefix && name.length - prefix.length >= 2) {
      name = name.slice(prefix.length);
    }

    // 去掉「-」「—」及之后
    name = name.split(/[-—–]/)[0].trim();

    // 编号类（3号楼 / A座）没有采邑意味
    if (/^[0-9A-Za-z]/.test(name)) return '';

    // 长度约束：2–4 字（1 字太泛）
    if (name.length < 2) return '';
    if (name.length > 4) name = name.slice(0, 2);

    // 泛词黑名单
    if (GENERIC_STEMS.indexOf(name) >= 0) return '';

    return name;
  }

  /** 是否已知城市名（城市名只用于王/公级，低阶不用，否则「上海伯」不成体统） */
  function isCityName(name) {
    return Object.prototype.hasOwnProperty.call(CITY_ALIASES, name);
  }

  /** 封号叠字检查：夫子+子 = 夫子子 这种要避免 */
  function awkwardJunction(fief, suffix) {
    if (!fief || !suffix) return false;
    return fief.charAt(fief.length - 1) === suffix.charAt(0);
  }

  /** 判断地点名/地址里属于哪个已知城市 */
  function cityOf(text) {
    if (!text) return '';
    for (var city in CITY_ALIASES) {
      if (!Object.prototype.hasOwnProperty.call(CITY_ALIASES, city)) continue;
      if (String(text).indexOf(city) >= 0) return city;
    }
    return '';
  }

  /** 城市 → 古称（没有古称返回空） */
  function ancientNameOf(cityName) {
    var list = CITY_ALIASES[cityName];
    return list && list.length ? list[0] : '';
  }

  /** 省份 → 大区古称；也接受城市名（自动补省份） */
  function regionNameOf(pointsText) {
    var text = String(pointsText || '');
    for (var region in REGION_NAMES) {
      if (!Object.prototype.hasOwnProperty.call(REGION_NAMES, region)) continue;
      if (text.indexOf(region) >= 0) return REGION_NAMES[region];
    }
    // 文本里没有省名时，尝试从城市名反推省份
    for (var city in CITY_PROVINCE) {
      if (!Object.prototype.hasOwnProperty.call(CITY_PROVINCE, city)) continue;
      if (text.indexOf(city) >= 0) {
        var province = CITY_PROVINCE[city];
        if (Object.prototype.hasOwnProperty.call(REGION_NAMES, province)) return REGION_NAMES[province];
      }
    }
    return '';
  }

  /* ---------- 4. 封号装配 ---------- */

  /** 爵位 key → 封号后缀（王/公/侯/伯/子/男/士） */
  var RANK_SUFFIX = {
    commoner: '',
    shi: '士',
    nan: '男',
    zi: '子',
    bo: '伯',
    hou: '侯',
    gong: '公',
    wang: '王'
  };

  /**
   * 计算封号
   * @param {Array<{lat:number,lon:number,name?:string,address?:string}>} points 疆域内的地点
   * @param {{key:string,title:string}} rankInfo 爵位信息
   * @param {{spanM:number, pointCount:number}} stats 疆域统计
   * @returns {{ title:string, fief:string, rankTitle:string, basis:string, cities:string[] }}
   *   title     完整封号（如「幕府侯」）；取不到地名时只有爵位（如「侯爵」）
   *   fief      采邑名（如「幕府」）；空表示未冠名
   *   rankTitle 爵位名（如「侯爵」）
   *   basis     命名依据（给人看的说明）
   */
  function fiefNameOf(points, rankInfo, stats) {
    var list = (points || []).filter(function (p) {
      return p && typeof p.lat === 'number' && typeof p.lon === 'number';
    });
    var rankTitle = (rankInfo && rankInfo.title) || '白身';
    var rankKey = (rankInfo && rankInfo.key) || 'commoner';
    var suffix = RANK_SUFFIX[rankKey] || '';

    if (!list.length || !suffix) {
      return { title: rankTitle, fief: '', rankTitle: rankTitle, basis: '还没有疆域，暂不封号', cities: [] };
    }

    // 收集所有地名文本，识别涉及的城市
    var texts = list.map(function (p) {
      return [p.name || '', p.address || ''].join(' ');
    });
    var cityTally = {};
    var cities = [];
    texts.forEach(function (t) {
      var c = cityOf(t);
      if (!c) return;
      cityTally[c] = (cityTally[c] || 0) + 1;
      if (cities.indexOf(c) < 0) cities.push(c);
    });
    // 治所 = 地点最多的那座城（封号以治所为号，这是汉唐通例）
    var seat = '';
    var seatCount = -1;
    cities.forEach(function (c) {
      if (cityTally[c] > seatCount) { seat = c; seatCount = cityTally[c]; }
    });

    // ---- 王 / 公：优先用城市古称或大区古称 ----
    if (rankKey === 'wang' || rankKey === 'gong') {
      if (cities.length === 1) {
        var ancient = ancientNameOf(cities[0]);
        if (ancient) {
          return {
            title: ancient + suffix,
            fief: ancient,
            rankTitle: rankTitle,
            basis: cities[0] + ' 古称「' + ancient + '」',
            cities: cities
          };
        }
      } else if (cities.length > 1) {
        var seatProvince = CITY_PROVINCE[seat] || '';
        var region = seatProvince && Object.prototype.hasOwnProperty.call(REGION_NAMES, seatProvince)
          ? REGION_NAMES[seatProvince]
          : '';
        if (region) {
          return {
            title: region + suffix,
            fief: region,
            rankTitle: rankTitle,
            basis: '疆域跨 ' + cities.length + ' 城，以治所「' + seat + '」所在取大区古称「' + region + '」',
            cities: cities
          };
        }
      }
      // 没有古称 → 用城市名本身
      if (cities.length >= 1) {
        return {
          title: cities[0] + suffix,
          fief: cities[0],
          rankTitle: rankTitle,
          basis: '以所在城市「' + cities[0] + '」为封',
          cities: cities
        };
      }
    }

    // ---- 侯 + 跨城：特例「关内侯」（历史真实爵位，表跨越关塞的大片封地）----
    if (rankKey === 'hou' && cities.length > 1) {
      var houProvince = CITY_PROVINCE[seat] || '';
      var houRegion = houProvince && Object.prototype.hasOwnProperty.call(REGION_NAMES, houProvince)
        ? REGION_NAMES[houProvince]
        : '';
      if (houRegion) {
        return {
          title: houRegion + suffix,
          fief: houRegion,
          rankTitle: rankTitle,
          basis: '疆域跨 ' + cities.length + ' 城，以治所「' + seat + '」取大区古称「' + houRegion + '」',
          cities: cities
        };
      }
      return {
        title: '关内侯',
        fief: '关内',
        rankTitle: rankTitle,
        basis: '疆域跨 ' + cities.length + ' 城，依汉制「关内侯」泛封',
        cities: cities
      };
    }

    // ---- 其余：从地点专名里选一个 ----
    var candidates = [];
    list.forEach(function (p) {
      var proper = properNameOf(p.name);
      if (!proper) return;
      // 低阶爵位不用城市名做封邑（「上海伯」不如「紫峰伯」得体），王/公已在上面单独处理
      if (isCityName(proper)) return;
      // 与爵位后缀叠字（夫子+子 → 夫子子）跳过，换下一个候选
      if (awkwardJunction(proper, suffix)) return;
      candidates.push({ proper: proper, source: p.name });
    });

    if (!candidates.length) {
      return {
        title: rankTitle,
        fief: '',
        rankTitle: rankTitle,
        basis: '领地内没有可用的地名，暂不冠名',
        cities: cities
      };
    }

    // 同名合并计数（出现次数多的更「有代表性」）
    var tally = {};
    candidates.forEach(function (c) {
      tally[c.proper] = (tally[c.proper] || 0) + 1;
    });
    candidates.sort(function (a, b) {
      if (tally[b.proper] !== tally[a.proper]) return tally[b.proper] - tally[a.proper];
      // 同频次时取更长的（更具体）
      return b.proper.length - a.proper.length;
    });

    var chosen = candidates[0];
    return {
      title: chosen.proper + suffix,
      fief: chosen.proper,
      rankTitle: rankTitle,
      basis: '取自「' + chosen.source + '」',
      cities: cities
    };
  }

  var api = {
    CITY_ALIASES: CITY_ALIASES,
    REGION_NAMES: REGION_NAMES,
    RANK_SUFFIX: RANK_SUFFIX,
    properNameOf: properNameOf,
    cityOf: cityOf,
    ancientNameOf: ancientNameOf,
    regionNameOf: regionNameOf,
    fiefNameOf: fiefNameOf
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (root) root.BW_FIEF = api;
})(typeof window !== 'undefined' ? window : (typeof global !== 'undefined' ? global : this));
