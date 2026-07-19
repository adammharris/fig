```fig
title = fig build instructions
author = adammharris
date = 2026-07-04
updated = 2026-07-04T15:48:19-06:00
```

# Building `fig`

You will need:
- [Access to a terminal](https://share.google/CzgpcLKGi8PKS4q7G)
- [Zig toolchain version 0.16.0](https://ziglang.org/download/)
- [Git](https://git-scm.com/install)

You will:
1. Use Git to download the code for `fig`
2. Go into the downloaded code folder
3. Use Zig to compile the code into an executable

Put these commands into the terminal and run them:

```bash
git clone https://github.com/diaryx-org/fig
cd fig
zig build
```

Now the code is compiled!

<details>
  <summary>Extra details about compilation</summary>
  <p>By default, <code>fig</code> compiles in "Debug" mode, which essentially means "as quickly as possible." There are lots of different ways to compile `fig`. The default build command gives you everything you need, but you can make the binary smaller with <code>zig build -Doptimize=ReleaseSmall</code>, or faster with <code>zig build -Doptimize=ReleaseFast</code>. The binary distributed to users through packages like Homebrew are compiled with <code>zig build -Doptimize=ReleaseSafe</code>, which provides extra safety in case of bugs or crashes, and a good balance of binary size and speed.</p>
</details>

In the `fig` folder, a new folder called `zig-out` has been created.
- The command-line tool is at `zig-out/bin/fig`.
- The library file is at `zig-out/bin/libfig.a`.

You can run the command-line tool where it is:

```bash
./zig-out/bin/fig
```

It should print helpful instructions on how to use it.

# Installing `fig`

If you want easy access to the command-line tool without having to navigate to the proper folder every time, you will have to add it to your `PATH` shell variable. The standard way to do this is to move the compiled binary to a `bin` folder.

To install for just your user:

```bash
mv zig-out/bin/fig ~/.local/bin/
```

To install for for all users in the computer (this requires an admin password):

```bash
sudo mv zig-out/bin/fig /usr/local/bin
```

`fig` does not update itself to new versions automatically. To get the latest version, you will have to download the latest changes and repeat the above steps again:

```bash
cd fig
git pull
zig build
mv zig-out/bin/fig ~/.local/bin
```

You can use a **package manager** to make updating easier. Right now, `fig` only supports Homebrew for macOS:

- [Install Homebrew](https://brew.sh)
- Run `brew tap diaryx-org/tap && brew install diaryx-org/tap/fig`
- To update, run `brew upgrade diaryx-org/tap/fig`

## nix-darwin

I personally use Nix on my Macbook to manage packages. I integrate it with Homebrew by adding this to my `configuration.nix`:

```nix
homebrew = {
  enable = true;
  taps = [
    "diaryx-org/tap"
  ];
  brews = [
    "fig"
  ];
};
```

`fig` isn't an official Nix package, but I'm sure Linux users are smart enough to figure it out!

# Changing Code

If you want, you can make changes to the code in the `src` folder and then run `zig build` again to see how your changes affected the `fig` binary.

If you make changes and want to share them with me, be sure to follow the instructions [here](CONTRIBUTING.md).