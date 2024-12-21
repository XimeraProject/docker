# Dockerfiles and docker images for Ximera

In this repository contains files needed to *build* Docker images for Ximera. 

Typical Ximera-authors are not concerned with the contents of this repo, as they will not *build* Docker images, but only *use* existing images, e.g 

`docker pull ghcr.io/ximeraproject/xake2024:v2.4.2`

`docker pull ghcr.io/ximeraproject/xake2024:v2.4.2-full`   # the same as above, but with a *full* TeXLive, and thus (much) bigger

The xake2024 images contain TeXLive and some supporting scripts and tools for compiling Ximera courses. In particular they contain a recent version of the `ximera` LaTeX package, and xmlatex en (lua-)xake tools needed to publish webversions of Ximera courses. Generating PDF versions can be done with 'pdflatex' in any recent TeX distribution. 

See the ximeraFirstSteps repo to get started with these images.

# Development

A new tag vX.xx automatically creates new xake2024:vX.xx, xake2024:vX.xx-medium and xake2024:vAxx-full images, that can be found on https://github.com/orgs/XimeraProject/packages. See ximeraFirstSteps for currently used/usable versions.

# Planning

A v2.5 version of xake is being prepared, completely re-written in lua (and no longer in GO as the previous version). The lua-xake code is in this repo, and the old 'xake' repo is no longer used.

The folder 'server' contains a prototype Dockerfile for a ximeraServer, but no 'official' versions exist currently.
