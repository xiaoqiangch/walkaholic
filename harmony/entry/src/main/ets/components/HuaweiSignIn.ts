/**
 * 华为账号（HUAWEI ID）登录 —— 客户端侧
 *
 * 鸿蒙应用的原生登录方式是**华为账号**，不是 Apple 登录。
 * （之前照搬 iOS 的「通过 Apple 登录」是平台错乱，已移除。）
 *
 * 职责边界
 * --------
 * 客户端只负责拿 `authorizationCode`；换 OpenID / 建会话的活在服务端 ——
 * 因为 client_secret 绝不能下发到客户端。
 *
 * 官方流程（@hms.core.authentication）：
 *   provider = new HuaweiIDProvider()
 *   request  = provider.createLoginWithHuaweiIDRequest()
 *   response = await new AuthenticationController(context).executeRequest(request)
 *   code     = response.data.authorizationCode
 *
 * 前置条件（缺任何一项都拿不到 code，UI 会如实提示，不假装成功）：
 *   1. 应用在 AGC 注册并开通「华为账号」服务
 *   2. AGC 配好 OAuth Client ID，包名与签名证书指纹一致
 *   3. 设备已登录华为账号
 */

import { authentication } from '@kit.AccountKit';
import { common } from '@kit.AbilityKit';

/** 取授权码的结果：code 非空才算成功，reason 用于如实告诉用户为什么失败 */
export interface HuaweiAuthCodeResult {
  code: string;
  /** 空串 = 成功；否则是给用户看的原因 */
  reason: string;
}

/**
 * 拉起华为账号授权，返回授权码。
 * 用户主动取消不算错误，返回空 code + 空 reason。
 */
export async function requestHuaweiAuthCode(): Promise<HuaweiAuthCodeResult> {
  let controller: authentication.AuthenticationController;
  try {
    const context: common.UIAbilityContext = getContext() as common.UIAbilityContext;
    controller = new authentication.AuthenticationController(context);
  } catch (err) {
    return { code: '', reason: '拿不到应用上下文，华为账号登录启动失败' };
  }

  let response: authentication.LoginWithHuaweiIDResponse;
  try {
    const provider: authentication.HuaweiIDProvider = new authentication.HuaweiIDProvider();
    const request: authentication.LoginWithHuaweiIDRequest = provider.createLoginWithHuaweiIDRequest();
    // 只请求 OpenID：够做账号绑定，不碰手机号/邮箱等敏感范围
    request.forceLogin = false;
    request.state = String(Date.now());
    // executeRequest 声明返回基类 AuthenticationResponse；带 data 的是子类
    response = await controller.executeRequest(request) as authentication.LoginWithHuaweiIDResponse;
  } catch (err) {
    // 用户取消 / 未登录华为账号 / AGC 未配置，都会走到这里。
    // 具体错误码不透传给用户（对用户没意义），给一句能行动的提示。
    const message: string = err !== undefined && err !== null && typeof err['message'] === 'string'
      ? err['message'] as string
      : '';
    if (message.indexOf('cancel') >= 0 || message.indexOf('取消') >= 0) {
      return { code: '', reason: '' };
    }
    return {
      code: '',
      reason: '没能完成华为账号授权。请确认手机已登录华为账号，且本应用已在 AGC 开通「华为账号」服务。'
    };
  }

  const credential: authentication.LoginWithHuaweiIDCredential | undefined = response.data;
  const code: string = credential === undefined || credential.authorizationCode === undefined
    ? ''
    : credential.authorizationCode;
  if (code.length === 0) {
    return { code: '', reason: '华为账号没有返回授权码，请稍后再试' };
  }
  return { code: code, reason: '' };
}
