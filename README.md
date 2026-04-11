<p align="center">
  <img src="https://github.com/Scottts/Kelux/blob/main/logo.png" alt="Kelux Logo" width="128">
</p>

<h1 align="center">Kelux</h1>

<p align="center">
  A high-performance Roblox runtime framework for modular system development.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/status-active-3fb950" alt="Status">
  <img src="https://img.shields.io/badge/source-open-success" alt="Open Source">
  <img src="https://img.shields.io/badge/tier-Full%20%2B%20Lite-5865f2" alt="Tiers">
  <img src="https://img.shields.io/badge/platform-Roblox-blue" alt="Platform">
  <img src="https://img.shields.io/badge/license-Apache%202.0-success" alt="License">
</p>

<p align="center">
  <a href="https://github.com/Scottts/Kelux/wiki"><strong>Documentation</strong></a> ·
  <a href="https://github.com/Scottts/Kelux/releases"><strong>Releases</strong></a> ·
  <a href="https://github.com/Scottts/Kelux/issues"><strong>Issues</strong></a> ·
  <a href="https://github.com/Scottts/Kelux/security/advisories/new"><strong>Security</strong></a>
</p>

---

> [!NOTE]
> This repository is the **public home** of **Kelux**.
> It is used for framework releases, documentation, issue tracking, security reporting, and project updates.
>
> Kelux is currently structured around two tiers:
> * **Full** - stable, feature-complete runtime systems
> * **Lite** - lightweight or experimental variants

## What is Kelux?

Kelux is a modular Roblox runtime framework focused on high-performance system design.

It provides reusable building blocks for common runtime needs such as eventing, caching, pooling, state handling, and task orchestration, while staying flexible enough to fit into different project architectures.

Rather than enforcing a full game structure, Kelux focuses on giving developers strong low-level and mid-level runtime foundations they can compose however they want.

## Core Systems

Kelux currently centers around five primary runtime systems:

| Module        | Purpose                                                |
| ------------- | ------------------------------------------------------ |
| **FullBus**   | Event bus patterns for structured communication        |
| **FullCache** | High-performance caching with configurable behavior    |
| **FullPool**  | Object pooling for efficient reuse                     |
| **FullState** | Structured state containers and state-driven workflows |
| **FullTask**  | Task orchestration and async workflow support          |

Kelux also includes supporting components for signals, TTL handling, instance utilities, and related runtime functionality.

## Why Kelux?

Kelux is designed for developers who want:

* modular runtime systems
* clean separation of responsibilities
* reusable framework primitives
* performance-oriented foundations
* a distinction between stable and experimental surfaces

The framework is especially suited for projects that want structured systems without being locked into a monolithic architecture.

## Quick Start

A minimal example using Kelux from `ReplicatedStorage`:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Kelux = require(ReplicatedStorage.Kelux)

local bus = Kelux.createBus()

bus:Subscribe("PlayerJoined", function(player)
	print(player.Name .. " joined the game")
end)

bus:Publish("PlayerJoined", game.Players:GetPlayers()[1])
```

A simple cache example:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Kelux = require(ReplicatedStorage.Kelux)

local cache = Kelux.createCache({
	capacity = 100,
})

cache:Set("Coins", 250)
print(cache:Get("Coins"))
```

## Installation

Kelux can be integrated into your Roblox project by downloading a release or by directly copying the framework source into your shared runtime location.

A common setup is:

```text
ReplicatedStorage
└── Kelux
```

You can then require the framework from your shared code and create the systems you need through the top-level API.

## Public API

Kelux exposes a straightforward entry surface for its core systems:

```lua
local Kelux = require(ReplicatedStorage.Kelux)

local bus = Kelux.createBus()
local cache = Kelux.createCache()
local pool = Kelux.createPool()
local state = Kelux.createState()
local taskManager = Kelux.createTask()
```

Advanced options and system-specific behaviors should be documented in the relevant module pages.

## Tier Structure

Kelux is organized around two tiers.

| Tier     | Role                                                                    |
| -------- | ----------------------------------------------------------------------- |
| **Full** | Stable, feature-rich systems intended for production-oriented use       |
| **Lite** | Smaller or experimental variants intended for iteration and exploration |

This separation allows Kelux to keep stable runtime systems clean while still leaving room for experimentation.

## Project Structure

A simplified framework overview:

```text
Kelux
├── Full
├── Lite
├── Components
└── ...
```

The exact structure may evolve across releases, but the framework is generally separated by tier and shared supporting components.

## Documentation

Kelux documentation is intended to cover:

* installation and setup
* tier overview
* module guides
* API reference
* examples and recipes
* migration notes
* frequently asked questions

Suggested starting path:

1. Installation
2. Tier overview
3. Quick Start
4. Module guide for the first system you want to use

## Stability

Kelux development may separate stable and experimental work depending on the active branch and the tier being used.

If you are evaluating Kelux for production use, prefer the current stable release path and the documented **Full** modules.

## Testing

Kelux uses runtime validation and automated testing to improve reliability across its core systems.

As test coverage expands, the goal is to keep the framework’s central runtime modules predictable, safe, and easier to integrate into larger projects.

## Roadmap

Current and planned areas of improvement include:

* stronger documentation and onboarding
* more usage examples and recipes
* continued stabilization of core systems
* clearer migration guidance between versions
* better separation of stable and experimental surfaces

## Contributing

Contributions, suggestions, and documentation improvements are welcome.

Recommended future repository files include:

* `CONTRIBUTING.md`
* `SECURITY.md`
* `CODE_OF_CONDUCT.md`

These help make the project easier to understand, maintain, and contribute to over time.

## Versioning

Kelux uses versioned releases to track framework changes over time.

Release notes should be used to review:

* new systems or features
* fixes and behavior changes
* migration notes
* stability expectations for a given version

## License

Kelux is licensed under the terms provided in this repository.

See the project license and notice files for full details.

## Project Hub

Use this repository for:

* reading documentation
* tracking releases
* reporting bugs
* submitting security concerns
* following framework updates
