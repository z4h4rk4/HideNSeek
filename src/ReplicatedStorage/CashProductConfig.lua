--!strict

return table.freeze({
	SHOP_GUI_NAME = "ShopGui",
	SHOP_MAIN_FRAME_NAME = "ShopMainFrame",
	SCROLLING_FRAME_NAME = "ScrollingFrame",
	CASH_FRAME_NAME = "Cash",
	BUY_BUTTON_NAME = "RobuxPriceBtn",

	UI_BIND_TIMEOUT_SECONDS = 20,
	PRODUCT_INFO_RETRY_SECONDS = 10,
	PURCHASE_PROMPT_TIMEOUT_SECONDS = 15,
	DONATE_PRODUCT_ID = 3709390431,
	DONATE_PROMPT_NAME = "DonatePrompt",
	DONATE_PROMPT_ATTRIBUTE = "OpensDonateProduct",
	DONATE_PROMPT_ACTION_TEXT = "Donate",
	DONATE_PROMPT_OBJECT_TEXT = "Donate",
	DONATE_PROMPT_DISTANCE = 10,

	PRODUCTS = table.freeze({
		table.freeze({
			Key = "Cash1000",
			FrameName = "1000",
			ProductId = 3709243832,
			Amount = 1000,
		}),
		table.freeze({
			Key = "Cash2500",
			FrameName = "2500",
			ProductId = 3709243863,
			Amount = 2500,
		}),
		table.freeze({
			Key = "Cash5000",
			FrameName = "5000",
			ProductId = 3709243881,
			Amount = 5000,
		}),
	}),
})
