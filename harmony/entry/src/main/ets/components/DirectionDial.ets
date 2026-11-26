/**
 * 方向罗盘（首页主交互）
 *
 * 为什么要有它
 * ------------
 * 原来首页只有一个「开一个盲盒」按钮 —— 用户没有表达意图的机会。
 * 但真实散步场景里，人往往**已经决定往哪走**（去地铁站、回家、顺路买东西）。
 * 所以改成罗盘：点「东」就向东边探索，方向和用户的真实去向一致，
 * 盲盒不再打断行程，而是**顺着行程长出来**。
 *
 * 交互
 * ----
 * - 上下左右四个方向键 → 朝该方向探索（引擎侧 direction 扇区过滤）
 * - 正中间「在此埋下」→ 在当前位置埋一个盲盒（原 bury 流程）
 * - 有进行中的旅程时，罗盘整体变成「继续」入口，避免误触开新盒
 *
 * 设计
 * ----
 * - 同心圆轨道（外圈虚线 + 内圈浅底），营造「罗盘」而非「按钮组」
 * - 四向按钮用方位字（北/东/南/西）+ 箭头，字号比正文小，靠位置表意
 * - 中心按钮用品牌色实心，视觉权重最高
 */
import { WASize, WAFont, WAColor, WA_DUR_QUICK, WA_EASE } from '../theme/Theme';

/** 四个方向：方位角沿用地理惯例（0=北，顺时针） */
export interface DialDirection {
  bearing: number;
  label: string;
}

const DIRECTIONS: DialDirection[] = [
  { bearing: 0, label: '北' },
  { bearing: 90, label: '东' },
  { bearing: 180, label: '南' },
  { bearing: 270, label: '西' }
];

@Component
export struct DirectionDial {
  /** 罗盘直径；首页按可用宽度给 */
  @Prop dialSize: number = 236;
  /**
   * 手机朝向（度，0=正北，顺时针）。>=0 时整个罗盘跟着手机转，
   * 让「北」始终指向真实北方。负值 = 罗盘不可用（静止朝北）。
   */
  @Prop heading: number = -1;
  /** 罗盘不可用时的提示 */
  @Prop headingUnavailable: boolean = false;
  /** 有进行中的旅程时，中心变成「继续」 */
  @Prop hasActiveSession: boolean = false;
  /** 中心按钮副标题（旅程剩余米数等） */
  @Prop sessionCaption: string = '';

  onExploreDirection: (bearing: number) => void = () => {
  };
  onBuryHere: () => void = () => {
  };
  onResume: () => void = () => {
  };

  @State private pressedBearing: number = -1;
  @State private centerPressed: boolean = false;

  private dirButtonSize(): number {
    return Math.max(46, Math.round(this.dialSize * 0.215));
  }

  private centerSize(): number {
    return Math.max(74, Math.round(this.dialSize * 0.335));
  }

  /** 按钮文字的反向旋转角：父级转了 -heading，这里补回 +heading */
  private counterAngle(): number {
    const h: number = this.heading;
    if (h < 0) return 0;
    return h;
  }

  /** 旋转层角度：-heading（让北指向真实北） */
  private rotorAngle(): number {
    const h: number = this.heading;
    if (h < 0) return 0;
    return 0 - h;
  }

  /** 方向按钮的轨道半径 */
  private orbitRadius(): number {
    return (this.dialSize - this.dirButtonSize()) / 2 - 2;
  }

  @Builder
  directionButton(dir: DialDirection) {
    Column({ space: 1 }) {
      Text(dir.label)
        .fontSize(WAFont.captionSm)
        .fontWeight(FontWeight.Medium)
        .fontColor(WAColor.amber)
      Text(this.arrowFor(dir.bearing))
        .fontSize(WAFont.microSm)
        .fontColor(WAColor.amberDeep)
    }
    .width(this.dirButtonSize())
    .height(this.dirButtonSize())
    .justifyContent(FlexAlign.Center)
    .borderRadius(this.dirButtonSize() / 2)
    .backgroundColor(WAColor.paper)
    .border({ width: 1, color: WAColor.amberBorder })
    .shadow({ radius: 6, color: WAColor.shadowSoft, offsetX: 0, offsetY: 1 })
    // 反向旋转抵消父级旋转：按钮「位置」跟着罗盘转到真实方位，但文字始终正着
    .rotate({ angle: this.counterAngle() })
    .scale({ x: this.pressedBearing === dir.bearing ? 0.91 : 1, y: this.pressedBearing === dir.bearing ? 0.91 : 1 })
    .animation({ duration: WA_DUR_QUICK, curve: WA_EASE })
    .onClick(() => {
      this.onExploreDirection(dir.bearing);
    })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) this.pressedBearing = dir.bearing;
      if (event.type === TouchType.Up || event.type === TouchType.Cancel) this.pressedBearing = -1;
    })
    .accessibilityText('向' + this.fullLabel(dir.bearing) + '探索')
  }

  private arrowFor(bearing: number): string {
    if (bearing === 0) return '↑';
    if (bearing === 90) return '→';
    if (bearing === 180) return '↓';
    return '←';
  }

  private fullLabel(bearing: number): string {
    if (bearing === 0) return '北';
    if (bearing === 90) return '东';
    if (bearing === 180) return '南';
    return '西';
  }

  @Builder
  centerButton() {
    Column({ space: 2 }) {
      Text(this.hasActiveSession ? '继续' : '在此埋下')
        .fontSize(this.hasActiveSession ? WAFont.titleSm : WAFont.bodySm)
        .fontWeight(FontWeight.Medium)
        .fontColor(WAColor.paper)
      if (this.hasActiveSession && this.sessionCaption.length > 0) {
        Text(this.sessionCaption)
          .fontSize(WAFont.microSm)
          .fontColor(WAColor.paper)
          .opacity(0.82)
      } else if (!this.hasActiveSession) {
        Text('埋一个盲盒')
          .fontSize(WAFont.microSm)
          .fontColor(WAColor.paper)
          .opacity(0.82)
      }
    }
    .width(this.centerSize())
    .height(this.centerSize())
    .justifyContent(FlexAlign.Center)
    .borderRadius(this.centerSize() / 2)
    .backgroundColor(this.hasActiveSession ? WAColor.teal : WAColor.amberDeep)
    // 内圈高光：让中心按钮看起来是「凸起的实体」，而不是一块色块
    .border({ width: 3, color: this.hasActiveSession ? '#33FFFFFF' : '#26FFFFFF' })
    .shadow({ radius: 14, color: WAColor.shadowLift, offsetX: 0, offsetY: 4 })
    .scale({ x: this.centerPressed ? 0.94 : 1, y: this.centerPressed ? 0.94 : 1 })
    .animation({ duration: WA_DUR_QUICK, curve: WA_EASE })
    .onClick(() => {
      if (this.hasActiveSession) {
        this.onResume();
      } else {
        this.onBuryHere();
      }
    })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) this.centerPressed = true;
      if (event.type === TouchType.Up || event.type === TouchType.Cancel) this.centerPressed = false;
    })
    .accessibilityText(this.hasActiveSession ? '继续上次的旅程' : '在当前位置埋一个盲盒')
  }

  /** 罗盘刻度：8 个方位各一小段，主方位（四正）稍长 */
  @Builder
  tick(angleDeg: number, isCardinal: boolean) {
    Column()
      .width(2)
      .height(isCardinal ? 9 : 5)
      .borderRadius(1)
      .backgroundColor(isCardinal ? WAColor.amberBorder : WAColor.line)
      .position({
        x: this.dialSize / 2 - 1 + Math.sin((angleDeg * Math.PI) / 180) *
          (this.dialSize / 2 - (isCardinal ? 5 : 3)),
        y: this.dialSize / 2 - (isCardinal ? 9 : 5) / 2 - Math.cos((angleDeg * Math.PI) / 180) *
          (this.dialSize / 2 - (isCardinal ? 5 : 3))
      })
      .rotate({ angle: angleDeg })
  }

  /** 罗盘主体：环 + 刻度 + 四向按钮（这一层跟着手机朝向旋转） */
  @Builder
  rotatingDial() {
    Stack({ alignContent: Alignment.Center }) {
      // ⓪ 罗盘刻度（八个方位，先画在最底层）
      ForEach([0, 45, 90, 135, 180, 225, 270, 315], (deg: number) => {
        this.tick(deg, deg % 90 === 0)
      }, (deg: number) => 'tick' + String(deg))

      // ① 外圈虚线轨道
      Circle()
        .width(this.dialSize)
        .height(this.dialSize)
        .fill(Color.Transparent)
        .stroke(WAColor.line)
        .strokeWidth(1)
        .strokeDashArray([4, 5])

      // ② 内圈浅底（让中间按钮浮起来）
      Circle()
        .width(this.dialSize * 0.62)
        .height(this.dialSize * 0.62)
        .fill(WAColor.paperHalf)
        .stroke(WAColor.lineSoft)
        .strokeWidth(1)
        .shadow({ radius: 8, color: WAColor.shadowSoft, offsetX: 0, offsetY: 2 })

      // ③ 四个方向键（@Builder 不能直接挂 .position，包一层 Stack 再定位）
      ForEach(DIRECTIONS, (dir: DialDirection) => {
        Stack({ alignContent: Alignment.Center }) {
          this.directionButton(dir)
        }
        .width(this.dirButtonSize())
        .height(this.dirButtonSize())
        .position({
          x: this.dialSize / 2 - this.dirButtonSize() / 2 + Math.sin((dir.bearing * Math.PI) / 180) *
            this.orbitRadius(),
          y: this.dialSize / 2 - this.dirButtonSize() / 2 - Math.cos((dir.bearing * Math.PI) / 180) *
            this.orbitRadius()
        })
      }, (dir: DialDirection) => String(dir.bearing))
    }
    .width(this.dialSize)
    .height(this.dialSize)
  }

  /** 正北标记：罗盘旋转时跟着转到真实北方 */
  @Builder
  northMark() {
    Text('▲')
      .fontSize(9)
      .fontColor(WAColor.ember)
      .position({ x: this.dialSize / 2 - 5, y: 0 })
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 旋转层：环 + 刻度 + 四向按钮 + 正北标记，一起跟着手机转
      Stack({ alignContent: Alignment.Center }) {
        this.rotatingDial()
        this.northMark()
      }
      .width(this.dialSize)
      .height(this.dialSize)
      .rotate({ angle: this.rotorAngle() })

      // 中心按钮不跟着转（「在当前位置埋下」与朝向无关）
      this.centerButton()
    }
    .width(this.dialSize)
    .height(this.dialSize)
  }
}
