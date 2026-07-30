PORTNAME=	rk3588-installer
DISTVERSION=	0.3.0
CATEGORIES=	sysutils

MAINTAINER=	am910021@gmail.com
COMMENT=	FreeBSD installer for RK3588 U-Boot systems

LICENSE=	BSD2CLAUSE

DISTFILES=
NO_ARCH=	yes
NO_BUILD=	yes

SUB_FILES=	rk3588-install

PLIST_FILES=	sbin/rk3588-install

do-install:
	${INSTALL_SCRIPT} ${WRKDIR}/rk3588-install \
	    ${STAGEDIR}${PREFIX}/sbin/rk3588-install

.include <bsd.port.mk>
