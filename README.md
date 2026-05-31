<p align="center">
  <h1 align="center">CNN Inference Engine ASIC<br>Complete RTL-to-GDSII Physical Design Flow</h1>
</p>

<p align="center">
  <strong>Energy-Efficient & High-Throughput CNN Accelerator for Edge AI Applications</strong><br>
  International Institute of Information Technology, Bangalore (IIIT-B)
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Technology_Node-45nm_CMOS-informational?style=flat-square" alt="Tech Node">
  <img src="https://img.shields.io/badge/EDA_Tools-Cadence_Genus_|_Innovus-critical?style=flat-square" alt="Tools">
  <img src="https://img.shields.io/badge/Flow-RTL_to_GDSII-blue?style=flat-square" alt="Flow">
  <img src="https://img.shields.io/badge/Status-Completed-brightgreen?style=flat-square" alt="Status">
</p>

---

## Table of Contents

* [Abstract](#abstract)
* [Motivation](#motivation)
* [Architecture Overview](#architecture-overview)
* [Key Features](#key-features)
* [Design Specifications](#design-specifications)
* [Physical Design Flow](#physical-design-flow)
* [Optimization Techniques](#optimization-techniques)
* [MMMC Analysis](#mmmc-analysis)
* [Power Planning](#power-planning)
* [Timing Closure](#timing-closure)
* [Final Results](#final-results)
* [Repository Structure](#repository-structure)
* [Tools and Technology](#tools-and-technology)
* [Team](#team)
* [Reference](#reference)
* [Acknowledgements](#acknowledgements)

---

## Abstract

This project demonstrates a complete RTL-to-GDSII ASIC implementation of an energy-efficient CNN Inference Engine designed for edge AI applications. The architecture is based on the work by Islam et al., focusing on memory-sharing and data-reusing techniques to improve throughput while minimizing power consumption.

The design implements an 864 Processing Element (PE) array using Q8.8 fixed-point arithmetic and undergoes the complete ASIC physical design flow using Cadence Genus and Innovus on the gsclib045 45nm CMOS technology node.

A combination of RTL-level, synthesis-level, and physical-design optimizations achieved a **61.6% reduction in dynamic power consumption**, while maintaining successful timing closure, DRC-clean routing, and GDSII sign-off.

---

## Motivation

Modern edge AI systems require CNN accelerators that are:

* Energy-efficient
* Area-efficient
* High-throughput
* Scalable for embedded deployment

Traditional GPU-based inference systems consume excessive power for edge environments such as:

* IoT devices
* Smart sensors
* Autonomous systems
* Embedded AI accelerators

This project explores ASIC-based CNN acceleration using aggressive optimization techniques across the entire VLSI design flow.

---

## Architecture Overview

The CNN inference engine consists of three primary modules:

| Module                                | Function                                                                    |
| :------------------------------------ | :-------------------------------------------------------------------------- |
| **KPU (Kernel Processing Unit)**      | 864 Processing Elements arranged in a 9×96 array for convolution operations |
| **IEC (Inference Engine Controller)** | Controls data flow between DRAM, KPU, and Classification Unit               |
| **CU (Classification Unit)**          | Performs final argmax-based classification                                  |

The architecture achieves:

* 95.9% compute efficiency
* 266-cycle inference latency
* Memory-sharing based optimization
* Data-reusing based throughput enhancement

---

## Key Features

| Feature                         | Description                                 |
| :------------------------------ | :------------------------------------------ |
| **864 PE Array**                | Large-scale parallel CNN computation engine |
| **Q8.8 Fixed-Point Arithmetic** | Low-power 16-bit datapath implementation    |
| **Complete RTL-to-GDSII Flow**  | Full ASIC implementation and sign-off       |
| **MMMC Timing Analysis**        | Fast and Slow corner timing verification    |
| **Clock Gating**                | Large-scale reduction in switching activity |
| **Operand Isolation**           | Prevents unnecessary multiplier toggling    |
| **Multi-Vt Optimization**       | Leakage-aware synthesis mapping             |
| **Post-Route Timing Closure**   | Fully routed and timing-clean design        |

---

## Design Specifications

| Parameter        | Value                 |
| :--------------- | :-------------------- |
| Technology Node  | gsclib045 (45nm CMOS) |
| Clock Frequency  | 100 MHz               |
| Supply Voltage   | 1.0V – 1.2V           |
| PE Array         | 864 PEs (9×96)        |
| Data Precision   | Q8.8 Fixed Point      |
| Total Instances  | 1.1M+                 |
| Total Nets       | 1.29M+                |
| Core Utilization | ~50%                  |
| Chip Area        | 7.60 mm²              |
| Throughput       | 0.1657 TOPS           |

---

## Physical Design Flow

The following ASIC flow was implemented:

1. RTL Optimization
2. Logic Synthesis
3. MMMC Setup
4. Floorplanning
5. Power Planning
6. Placement Optimization
7. Clock Tree Synthesis (CTS)
8. Global & Detailed Routing
9. RC Extraction
10. Post-Route Timing Closure
11. GDSII Generation

---

## Optimization Techniques

### RTL-Level Optimizations

| Technique              | Purpose                                          |
| :--------------------- | :----------------------------------------------- |
| Clock Gating           | Reduces unnecessary clock toggling               |
| Operand Isolation      | Prevents multiplier switching for invalid inputs |
| Bus Gating             | Reduces interconnect switching activity          |
| Gray-Coded FSM         | Minimizes FSM transition toggling                |
| Output Register Gating | Prevents idle register activity                  |

### Synthesis-Level Optimizations

| Technique              | Purpose                            |
| :--------------------- | :--------------------------------- |
| Automatic Clock Gating | Genus-based clock gating insertion |
| Multi-Vt Mapping       | Leakage-aware cell assignment      |
| High-Effort Synthesis  | Improved QoR optimization          |

---

## MMMC Analysis

The design was verified across multiple PVT corners using MMMC methodology.

| Corner    | Voltage | Temperature | Purpose        |
| :-------- | :------ | :---------- | :------------- |
| Fast (FF) | 1.2V    | -40°C       | Hold Analysis  |
| Slow (SS) | 1.0V    | 125°C       | Setup Analysis |

Additional timing robustness was achieved using:

* OCV (On-Chip Variation)
* CPPR (Clock Path Pessimism Removal)

---

## Power Planning

The power delivery network consists of:

* Metal5 horizontal power rings
* Metal6 vertical power stripes
* Followpin routing for standard cell rails

### Key Decisions

| Parameter        | Value |
| :--------------- | :---- |
| Power Ring Width | 3 µm  |
| Stripe Pitch     | 30 µm |
| Core Margins     | 20 µm |
| Utilization      | 50%   |

The design minimizes IR-drop while supporting large-scale PE parallelism.

---

## Timing Closure

Timing closure was achieved through:

* Pre-CTS placement optimization
* Clock Tree Synthesis
* Post-route optimization
* Variation-aware optimization

### Final Timing Results

| Metric              | Result    |
| :------------------ | :-------- |
| Setup WNS           | +6.524 ns |
| Setup TNS           | 0         |
| Hold Violations     | 0         |
| DRC Violations      | 0         |
| Connectivity Errors | 0         |

---

## Final Results

| Metric                     | Value       |
| :------------------------- | :---------- |
| Total Power                | 340.15 mW   |
| Clock Power                | 35.21 mW    |
| Throughput                 | 0.1657 TOPS |
| Energy per Inference       | 904.8 nJ    |
| Dynamic Power Reduction    | 61.6%       |
| Total Clock Gates Inserted | 18,461      |
| Chip Area                  | 7.60 mm²    |

---

## Repository Structure

```text
.
├── RTL/
├── MMMC/
├── Synthesis/
├── Innovus/
├── Scripts/
├── Reports/
├── Outputs/
│   ├── GDSII/
│   ├── Timing_Reports/
│   ├── Power_Reports/
│   └── Layout_Images/
├── Documentation/
├── Final_Report.pdf
└── README.md
```

---

## Tools and Technology

| Component             | Details                             |
| :-------------------- | :---------------------------------- |
| Synthesis Tool        | Cadence Genus v23                   |
| Place & Route Tool    | Cadence Innovus v23.13              |
| Technology Library    | gsclib045                           |
| Technology Node       | 45nm CMOS                           |
| Timing Analysis       | MMMC + OCV                          |
| Physical Verification | DRC / Connectivity / Antenna Checks |

---

## Team

| Name                    | Roll Number |
| :---------------------- | :---------- |
| Siddhant Deore          | IMT2023539  |
| Sawant Hrushikesh Rahul | IMT2023619  |
| Satyam Ambi             | IMT2023623  |
| Ramkushal B             | IMT2023601  |
| Shubranil Basak         | IMT2023510  |
| Pratham Shetty          | IMT2023534  |

---

## Reference

Islam et al.,
**“Energy-Efficient and High-Throughput CNN Inference Engine Based on Memory-Sharing and Data-Reusing for Edge Applications”**
IEEE TCAS-I, Vol. 71, No. 7, July 2024.

---

## Acknowledgements

This project was completed as part of the **VLS-822 ASIC Physical Design Course Project** at the International Institute of Information Technology, Bangalore (IIIT-B).

---

<p align="center">
  <sub>© 2026 · IIIT Bangalore · ASIC Physical Design Project</sub>
</p>
