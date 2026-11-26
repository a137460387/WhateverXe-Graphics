# XeCompilerAdapter "unsupported serialized request" 修复报告

日期：2026-11-26  
环境：macOS 15.8.3 (Darwin 24.6.0) x86_64, Iris Xe 0xa7a0 rev04, WhateverXe kext 0.8.2 + Graphics 0.4.5  
分支：`fix/serialized-request`

---

## 1. 二进制一致性验证

| 文件 | sha256 |
|------|--------|
| `/Library/GPUBundles/XeCompilerAdapter.bundle/Contents/MacOS/adapter.dylib`（修复前） | `11609123ce5b930aee500736f8bd504cd0280c37654f8e9f353fcc9fc876aff0` |
| `payloads/Common/Library/GPUBundles/XeCompilerAdapter.bundle/Contents/MacOS/adapter.dylib` | `11609123ce5b930aee500736f8bd504cd0280c37654f8e9f353fcc9fc876aff0` |
| provenance 记录值 | `11609123ce5b930aee500736f8bd504cd0280c37654f8e9f353fcc9fc876aff0` |

**结论：三者一致，0.4.5 payload 未变更。**

`sysctl kern.osrelease` = `24.6.0` → Darwin 24 → `_select_route` 返回 route=2（modern AIR-v4 路径）。

---

## 2. 运行时取证与失败条件确认

### 2.1 lldb attach 受阻

SIP Debugging Restrictions 处于 enabled 状态（`csr-active-config=03080000`），MTLCompilerService 带 `com.apple.developer.hardened-process` entitlement，lldb attach 被拒：

```
error: attach failed: Not allowed to attach to process.
```

改用 **dlopen 探针**（自写 C 程序直接调用 adapter 导出函数）+ **崩溃日志分析** 取证。

### 2.2 崩溃日志证据

`~/Library/Logs/DiagnosticReports/Atoll-2026-11-26-150236.ips` 与 `150401.ips`：

```
termination.namespace = COREANIMATION
termination.details = ["spec=PBGRAXb_BclrXhf", "Xe compiler unsupported serialized request"]
                      ["spec=PRGhAXb_BclrXhfu", "Xe compiler unsupported serialized request"]
exception = EXC_CRASH / SIGABRT
faultingThread stack: __abort_with_payload ← CA::OGL::MetalContext::create_pipeline_state ← ... draw_elements
```

错误字符串 `"Xe compiler unsupported serialized request"` 唯一来源是 `0x13f4`（gate1 失败分支）。

### 2.3 反汇编验证 gate1（otool -tV 实测）

```asm
0x13e0: cmpq   $0xd8, %r14        ; r14 = arg2 (request size)
0x13e7: sete   %al
0x13ea: testl  %r15d, %r15d       ; r15d = arg3
0x13ed: sete   %cl
0x13f0: testb  %cl, %al
0x13f2: jne    0x13fd             ; 两者都满足才跳过 abort
0x13f4: leaq   "Xe compiler unsupported serialized request", %rax
0x13fb: jmp    0x13c5             ; → return 1
```

寄存器映射（函数序言 `0x12c0` 确认）：`rdi`=ctx, `rsi`=req, `rdx`→`r14`=size, `ecx`→`r15d`=arg3, `r8`→`r13`=air_ptr, `r9`→stack=airlen。

**确切失败条件：size != 216 或 arg3 != 0。** Atoll 的 CA shader spec（PRGhAXb_BclrXhfu / PBGRAXb_BclrXhf）传入的请求不满足此白名单。

### 2.4 dlopen 探针复现（受控环境）

将 adapter.dylib + libigc-tgl.dylib + runtime.igc64.bc 复制到短路径 `/tmp/xe-probe-env/`（避免 `MTLCompilerCreate` 内 `strlen(path) >= 0x385` 检查失败），ad-hoc 签名后直接调用：

```
case size=0xd8 arg3=0 -> ret=1 err=Xe compiler native AIR input extent
case size=0xe0 arg3=0 -> ret=1 err=Xe compiler unsupported serialized request
case size=0xd8 arg3=1 -> ret=1 err=Xe compiler unsupported serialized request
case size=0x100 arg3=0 -> ret=1 err=Xe compiler unsupported serialized request
```

**与崩溃日志完全吻合：非 216 字节请求必触发 gate1 abort。**

### 2.5 对 Windows 侧结论的修正

Windows 侧称 AIR 长度接受区间为 `[0x100001, 0x200003]`。**实际字节语义相反：**

```asm
0x140a: lea    rcx, [r13 - 0x100001]
0x1411: cmp    rcx, 0xfff00003      ; sign-ext → 0xFFFFFFFFFFF00003
0x1418: setb   cl                   ; cl = (diff <u threshold)
0x141b: or     cl, al               ; al = (air_ptr == NULL)
0x141d: je     0x1428               ; PASS iff cl==0 → diff >= threshold
```

无符号比较下，`airlen - 0x100001 >=u 0xFFFFFFFFFFF00003` 仅在 `airlen ∈ [1, 0x100000]` 时成立（wrap-around 区域）。`airlen ≥ 0x100001` 时 diff 为小正数，**必被拒绝**。

探针实测证实：

```
airlen=0x100000 -> parse rejected（通过了 extent，进入 LLVM 解析）
airlen=0x100001 -> input extent（被拒）
airlen=0x180000 -> input extent（被拒）
```

直编路径 `0xda4` 的 extent 检查使用相同阈值和 `setae`，语义等价：**同样只接受 ≤ 1MiB**。两条路径对 ≥ 1MiB AIR 互斥拒绝，原版 adapter 在 Darwin 24 上无法编译任何 ≥ 1MiB 的 AIR-v4 输入。

> 注：Windows 侧所述"转换失败回落直编"也不准确。反汇编显示 parse-rejected 设置 err 字符串后直接返回失败（`0x1590` → cleanup → `r14 != 0` → return 1），**不回落**。直编回落仅在 LLVM 解析+序列化成功、且 `_parseable(converted)` 返回 true 时发生，传入的是转换后的 bitcode 而非原始 AIR。

### 2.6 未能获取的证据

- **真实请求结构体 dump**：lldb attach 被 SIP 阻止；无法在 MTLCompilerService 进程内断点读取 r14/ecx/rsi。探针只能验证合成请求，无法捕获 Atoll 实际发送的 size/arg3 具体值。
- **原版对照复现**：在部署原版 dylib 后，使用 AVPlayer+MediaRemote 媒体会话、Cmd+U 展开灵动岛、鼠标悬停、CIFilter 压测等多种触发手段，**均未复现崩溃**。可能原因：崩溃需要特定 shader spec 缓存状态或特定时序；历史崩溃发生在 13:33–15:04 时段，后续系统状态已变化。因此"修复有效"的证据强度受限——我们证明了 patch 消除了 gate1 拒绝路径，且修复后无新崩溃，但缺少同一触发条件下原版必崩的对照。

---

## 3. 修复路线选择

**路线 1（二进制 patch）**，理由：

- 崩溃点明确为 gate1 白名单过严，内容本身仍是合法 AIR-v4（CA 框架生成）。
- extent 检查存在逻辑 bug（接受区间与意图相反），需一并绕过才能让 ≥ 1MiB 的真实 shader 通过。
- 无需重写 dylib，3 字节改动最小化风险。
- ad-hoc 签名 + AMFIPass 1.4.1 实测放行（MTLCompilerService 成功加载 patched dylib 并编译 shader）。

未选路线 2（跳转直编）：直编路径有独立的 stage/state 白名单，且其 extent 检查同样拒绝 ≥ 1MiB；绕过 gate1 后走 AIR 转换路径更合理。  
未选路线 3（重写 dylib）：3 字节 patch 已足够，重写引入不必要的 ABI/签名风险。

---

## 4. Patch 具体内容

仅修改 `__text` 段 3 个字节（条件跳转 → 无条件跳转）：

| 文件偏移 | 原字节 | 新字节 | 指令变化 | 作用 |
|----------|--------|--------|----------|------|
| `0x13f2` | `75` | `eb` | `jne 0x13fd` → `jmp 0x13fd` | 跳过 size==0xd8 && arg3==0 检查 |
| `0x141d` | `74` | `eb` | `je 0x1428` → `jmp 0x1428` | 跳过 AIR 输入 extent 检查 |
| `0x153d` | `74` | `eb` | `je 0x1595` → `jmp 0x1595` | 跳过 AIR 输出 extent 检查 |

其余字节差异全部位于代码签名区域（ad-hoc 重签所致），代码区 `0x600..0x1db8` 仅上述 3 处变更。

应用方式：

```bash
python3 fixes/apply-patch.py fixes/adapter.dylib.orig fixes/adapter.dylib.patched
codesign -f -s - fixes/adapter.dylib.patched
sudo cp fixes/adapter.dylib.patched /Library/GPUBundles/XeCompilerAdapter.bundle/Contents/MacOS/adapter.dylib
sudo killall -9 MTLCompilerService
```

备份：`~/xe-adapter-backup/adapter.dylib.orig`（sha256 同原版）。

**memcpy 越界风险评估**：gate1 bypass 后，若真实 size > 0xd8，AIR 转换路径不使用 req size 做 memcpy（仅读 stage/state 字段）；直编回落硬编码 `movl $0xd8, %edx`（`0x1639`），但回落传入的是转换后 bitcode 而非原始 req，且 `_parseable` 先验证可编译性。输出 memcpy（`0x15af`）长度为 LLVM 序列化结果大小，与 req size 无关。**未发现因 size 放宽导致的越界写入路径。**

---

## 5. 验证结果

部署 patched dylib（sha256 `1f064c6d7db4d966d19053c73610e602f10cdc118185dd03a4e2bcbecbf44ca3`）后：

| # | 验证项 | 结果 | 证据 |
|---|--------|------|------|
| 1 | Atoll + 音乐 + 悬停灵动岛 | ✅ 不闪退 | AVPlayer MediaRemote 会话 + Cmd+U 展开 ×12 + 鼠标悬停，PID 19088 存活，无新 .ips |
| 2 | 照片 app 浏览 | ✅ 不闪退 | PID 18084 持续运行 >12s，无 Photos 崩溃报告 |
| 3 | system_profiler Metal | ✅ Metal 2 | `Metal Support: Metal 2` |
| 4 | log show Xe compiler abort | ✅ 无新 abort | `--last 5m` predicate 匹配 count=0 |
| 5 | 新崩溃报告 | ✅ 无 | deploy 时间戳后 .ips count=0 |
| 6 | MTLCompilerService 加载 | ✅ patched 生效 | vmmap 确认加载路径；自进程 dlopen 验证内存字节 `0x13f2=eb` |
| 7 | 40 个多样化 Metal pipeline 编译 | ✅ 全部成功 | stress.swift exit=0 |
| 8 | CIFilter/NSVisualEffectView CA 压测 | ✅ 无崩溃 | cametal/cablur/cifilters exit=0，MTLCompilerService 正常拉起 |

**局限**：原版对照未复现崩溃（见 §2.6），故不能断言"同一触发下原版必崩、patch 必不崩"。现有证据支持"patch 消除了 gate1/extent 拒绝路径，修复后系统稳定"，但因果闭环缺对照实验。

---

## 6. 遗留问题与建议

1. **真实请求 dump 缺失**：需关闭 SIP Debugging Restrictions（`csrutil enable --without debug`）或用内核级 hook 才能捕获 MTLCompilerService 内的实际 size/arg3 值。当前约束不动 boot-args，故未执行。
2. **extent 检查 bug 应上游修复**：接受区间逻辑与注释/意图相反，建议 upstream 将 `setb`/`setae` 修正为正确范围判定，而非简单 bypass。本 patch 是 workaround。
3. **第二层 state 校验未触发**：修复后未观察到 "unsupported vertex/fragment/compute state" 错误，说明真实 CA 请求的 state 区符合现有白名单，无需进一步放宽。
4. **IGC PreprocessMetadata 空指针**：探针用 runtime.igc64.bc（非 shader module）喂入 IGC 时触发 `AIR::PreprocessMetadata::runOnModule+207` 段错误。这是合成输入问题，不影响真实 shader；但与上游 issue #156/#187 的 TGL 空指针崩溃属同一函数区域，值得留意。
5. **长期稳定性**：建议持续观察数日，覆盖更多 app（Safari、Final Cut 等）和重启后场景。若出现新错误字符串，按 §3.2 探针方法迭代。

---

## 附录：文件清单

- `fixes/adapter.dylib.orig` — 原版二进制（sha256 11609123…）
- `fixes/adapter.dylib.patched` — 修复后二进制（含 ad-hoc 签名，sha256 1f064c6d…）
- `fixes/apply-patch.py` — 可重现 patch 脚本（校验原字节后修改 3 处）
- `~/xe-adapter-backup/adapter.dylib.orig` — 系统级备份