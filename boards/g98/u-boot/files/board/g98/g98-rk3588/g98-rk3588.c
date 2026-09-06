/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 Fang, Wei-Xiang (Yuri) <am910021@gmail.com>
 */

#include <button.h>
#include <env.h>
#include <stdio.h>

int
rk_board_late_init(void)
{
	struct udevice *button;

	if (button_get_by_label("F12", &button) != 0 ||
	    button_get_state(button) != BUTTON_ON)
		return 0;

	if (env_set("bootdelay", "-1") != 0) {
		puts("Recovery key held, but autoboot could not be stopped\n");
		return 0;
	}

	puts("Recovery key held; autoboot stopped\n");
	return 0;
}
