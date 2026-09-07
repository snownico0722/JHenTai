# JHenTai Windows × Bakabase

这是一个只放在 `windows/bakabase-direct-open` 分支里的 Windows 定制版，不准备向上游提 PR。

目标很简单：让 Bakabase 把本地 E-Hentai / ExHentai 漫画文件交给 JHenTai 后，JHenTai 直接进入对应漫画的阅读页。

## Bakabase 配置

在 Bakabase 的“配置播放器”中：

- **可执行文件路径**：选择这个定制版的 `jhentai.exe`
- **命令模板**：`{0}`
- **支持的扩展名**：建议填写 `jpg`, `jpeg`, `png`, `gif`, `webp`

也可以把命令模板写成：

```text
--open {0}
```

两种写法效果相同。

## 打开规则

这个 Windows 版额外支持以下启动方式：

```text
jhentai.exe "D:\Comics\Some Gallery\001.jpg"
jhentai.exe "D:\Comics\Some Gallery"
jhentai.exe --open "D:\Comics\Some Gallery\001.jpg"
jhentai.exe "https://e-hentai.org/g/123456/abcdef1234/"
```

当收到图片文件时，会把**图片所在文件夹**当作一本本地漫画，按 JHenTai 原本的自然排序规则读取该目录中的图片，然后直接进入阅读页。

因此不需要把 Bakabase 的漫画目录额外加入 JHenTai 的“额外画廊扫描路径”。

如果 JHenTai 已经在运行，新启动的 `jhentai.exe` 会把打开请求转给已有窗口并退出，不会每点一次 Bakabase 就留下一个新的 JHenTai 窗口。已有窗口如果最小化，会被恢复并获得焦点。

JHenTai 原有的本地阅读进度仍然生效；没有旧进度时，如果外部传入的是某张具体图片，则从那张图片开始。

## 当前范围

这个入口只处理：

- 单层图片文件夹：jpg / jpeg / png / gif / webp
- 直接传入一个图片文件
- 直接传入一个图片文件夹
- E-Hentai / ExHentai 画廊 URL

不会把 zip/cbz/rar 等压缩包自动解包，也不会递归把一个包含多本漫画的上级目录合并成一本漫画。
