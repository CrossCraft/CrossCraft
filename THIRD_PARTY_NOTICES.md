# Third-Party Notices for CrossCraft

CrossCraft is licensed under the GNU General Public License version 2 (GPLv2).
See the root `LICENSE` file for the full text.

This file contains licensing information for third-party code, algorithms, and documentation incorporated or adapted in the project.

Aether-Engine is not covered by these notices.

## ClassiCube (Dig Animation, Physics, View Bob, and Isometric Block Drawer)

Certain portions of this software were adapted from ClassiCube by UnknownShadow200.

**Sources used:**

- Dig animation: primarily from the official ClassiCube wiki descriptions
  - <https://github.com/ClassiCube/ClassiCube/wiki/Dig-animation-details>
- Physics and view-bob code: cross-referenced in part from the ClassiCube source code.
- Isometric block drawer (hotbar): adapted from ClassiCube's IsometricDrawer
  - <https://github.com/ClassiCube/ClassiCube/blob/master/src/IsometricDrawer.c>

The original ClassiCube work is licensed under the **BSD 3-Clause License**:

> Copyright (c) 2014 - 2024, UnknownShadow200
> All rights reserved.
>
> Redistribution and use in source and binary forms, with or without modification,
> are permitted provided that the following conditions are met:
>
> 1. Redistributions of source code must retain the above copyright notice, this
>    list of conditions and the following disclaimer.
> 2. Redistributions in binary form must reproduce the above copyright notice, this
>    list of conditions and the following disclaimer in the documentation and/or other
>    materials provided with the distribution.
> 3. Neither the name of ClassiCube nor the names of its contributors may be
>    used to endorse or promote products derived from this software without specific prior
>    written permission.
>
> THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY
> EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
> OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT
> SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
> SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT
> OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
> HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
> (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
> EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

**Modifications:**
The code was ported to Zig and adapted/integrated for use in CrossCraft (which uses the separate Aether-Engine). All changes, the Zig implementations, and any new code written for these features are licensed under the GNU General Public License version 2 (GPLv2), the same license as the rest of CrossCraft.
