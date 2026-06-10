DECLARE @s BIT, @m NVARCHAR(500);
EXEC Location.Location_GetTree
	@RootLocationId = 1;