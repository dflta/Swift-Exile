# Third-party notices

SwiftExile's own code is licensed under the PolyForm Noncommercial License 1.0.0 (see
[LICENSE](LICENSE)). The components below keep their own licenses; the noncommercial terms do not
apply to them.

## Exiled Exchange 2 / Awakened PoE Trade

SwiftExile bundles the renderer (user interface and item parser) of
[Exiled Exchange 2](https://github.com/Kvan7/Exiled-Exchange-2) by Kvan7, a fork of
[Awakened PoE Trade](https://github.com/SnosMe/awakened-poe-trade) by SnosMe.
The app bundle includes this license at `Contents/Resources/Licenses/ExiledExchange2-LICENSE.txt`.

```
MIT License

Copyright (c) 2020 Alexander Drozdov

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Renderer npm dependencies

The renderer build bundles npm packages (Vue, vue-i18n, Tailwind, and others) under their own
licenses. Every app bundle includes their license files in
`Contents/Resources/Licenses/npm/` (collected at build time by `Scripts/bundle-app.sh`).

## Swift packages

- [Hummingbird](https://github.com/hummingbird-project/hummingbird) and
  [hummingbird-websocket](https://github.com/hummingbird-project/hummingbird-websocket): Apache License 2.0
- [SwiftNIO](https://github.com/apple/swift-nio), [swift-http-types](https://github.com/apple/swift-http-types),
  and their Apple dependencies: Apache License 2.0
- [Sparkle](https://github.com/sparkle-project/Sparkle) (auto-updates): MIT License

Every app bundle includes their license and NOTICE files in
`Contents/Resources/Licenses/swift-packages/`.
