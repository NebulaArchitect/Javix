# Javix（精灵 Java）是一种新的编程语言

**Java 怎么写，我就怎么写；Java 跑不快、跑不了的地方，我全能跑。**

[![License](https://img.shields.io/badge/license-GPLv3-green)]()
[![Zig](https://img.shields.io/badge/Zig-0.16.0-orange)](https://ziglang.org/)

---

Javix 是一门语法完全贴合 Java、底层用 Zig 重写、编译为原生 exe / Wasm的新一代编程语言。**零 JVM、零依赖、毫秒启动、KB级体积。**

> ⚠️ v0.1.0-alpha：功能完整可用，部分高级特性（异常处理、泛型）待完善。

---

## 快速开始

### 方式一：文件编译（推荐）

```bash
# hello_javix.jx
fn main() -> void {
    print("Hello, Javix!");
}
```

```bash
javix build hello_javix.jx
./hello_javix.exe
```

### 方式二：REPL 交互

```bash
javix repl
>>> int x = 10;
>>> print(x);
10
```

---

## 语言特性

### 变量与类型

```java
int x = 42;
double pi = 3.14;
String name = "Javix";
boolean ok = true;
final int CONSTANT = 100;
```

### 控制流

```java
// for 循环
for (int i = 0; i < 10; i = i + 1) { print(i); }

// while / do-while
while (x > 0) { x = x - 1; }
do { run(); } while (alive);

// if/else + switch
if (score > 90) { print("A"); }
switch (n) { case 1,2: break; default: break; }
```

### 函数与递归

```java
fn factorial(n: int) -> int {
    if (n <= 1) return 1;
    return n * factorial(n - 1);
}
```

### 面向对象（继承/抽象/接口）

```java
class Animal {
    String name;
    fn speak() -> String { return "..."; }
}

class Dog extends Animal {
    String breed;
    fn speak() -> String { return "Woof!"; }
}

Dog d = new Dog("Rex", "Husky");
print(d.speak());  // Woof!
```

### 37 个内置函数

| 分类 | 函数 |
|------|------|
| String | `strlen`, `strsub`, `strequal`, `strtrim`, `strcontains` |
| Math | `mathAbs`, `mathMin`, `mathMax`, `mathPow`, `mathSqrt` |
| 转换 | `intToString`, `doubleToString` |
| 数组 | `arrayLen` |
| HTTP | `httpGet`, `httpPost` |
| JSON | `jsonGet` |
| Character | `charIsDigit`, `charIsLetter`, `charToUpper`, `charToLower` |
| 日期时间 | `currentTimeMillis` |
| 文件IO | `readFile`, `writeFile`, `fileAppend` |
| HashMap | `mapPut`, `mapGet`, `mapContainsKey` |
| ArrayList | `listCreate`, `listAdd`, `listGet`, `listSize` |
| 多线程 | `threadSleep` |

---

## 架构

```
Javix 源码 (.jx)
    → 词法分析 (lexer)
    → 语法分析 (parser) 
    → AST (ast)
    → 代码生成 (codegen → Zig 源码)
    → zig build-exe → 原生 exe / Wasm
```

- **编译器语言**: Zig 0.16.0
- **输出**: 原生 exe (Windows) / wasm32-wasi
- **运行时**: 零 JVM，直接调用 kernel32 (Windows)
- **体积**: 空项目 ~36KB (Wasm)

---

## 从源码构建

```bash
# 需要 Zig 0.16.0
git clone https://github.com/NebulaArchitect/javix.git
cd javix
zig build
./zig-out/bin/javix.exe build hello_javix.jx
```

---

## 已知限制 (v0.1.0-alpha)

- 函数参数格式为 `name: type`（非 Java 的 `type name`）
- 异常处理 try/catch 未实现
- 泛型/注解/Lambda 未实现
- 文件 IO 仅 Windows
- 字符串拼接仅限顶层作用域
- REPL 为实验性功能

---

## License

**GNU General Public License v3.0** — 自由使用、自由修改、自由分发。衍生作品必须同样以 GPL 开源，禁止闭源商用。

---

*"A language that feels like Java, runs like C, and goes everywhere Wasm can."*
