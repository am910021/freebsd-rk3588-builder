PORTNAME=	rge
PORTVERSION=	20260728
DISTVERSIONPREFIX=	v
CATEGORIES=	net
PKGNAMEPREFIX=	realtek-
PKGNAMESUFFIX=	-kmod

MAINTAINER=	am910021@gmail.com
COMMENT=	Kernel module for Realtek 8125/8126/8127 network cards
WWW=		https://github.com/am910021/if_rge_freebsd

LICENSE=	BSD2CLAUSE

USES=		kmod tar:tgz uidfix

USE_GITHUB=	yes
GH_ACCOUNT=	am910021
GH_PROJECT=	if_rge_freebsd
GH_TAGNAME=	d62834b2388c4f46334f4f1cacbd445afab4f90c

WRKSRC_SUBDIR=	src

MAKE_ENV+=	MACHINE="${MACHINE}" MACHINE_ARCH="${MACHINE_ARCH}"
.if defined(TARGET)
MAKE_ENV+=	TARGET="${TARGET}"
.endif
.if defined(TARGET_ARCH)
MAKE_ENV+=	TARGET_ARCH="${TARGET_ARCH}"
.endif
.if defined(KERNBUILDDIR)
MAKE_ENV+=	KERNBUILDDIR="${KERNBUILDDIR}"
.endif

PLIST_FILES=	${KMODDIR}/if_rge.ko \
		share/man/man4/rge.4.gz

post-install:
	${INSTALL_MAN} ${FILESDIR}/rge.4 \
	    ${STAGEDIR}${PREFIX}/share/man/man4

.include <bsd.port.mk>
