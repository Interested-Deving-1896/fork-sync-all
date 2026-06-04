import {Check, PlusCircle} from 'lucide-react';

import {Badge} from '@/components/ui/badge';
import {Button} from '@/components/ui/button';
import {
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
  CommandSeparator,
} from '@/components/ui/command';
import {Popover, PopoverContent, PopoverTrigger} from '@/components/ui/popover';
import {Separator} from '@/components/ui/separator';
import {cn} from '@/lib/utils';

export interface ComboBoxProps<T> {
  badgeRenderer?: typeof renderBadge;
  buttonClassName?: string;
  clearText?: string;
  items: T[];
  maxSelectedItemsToShow?: number;
  onItemsUpdate: (items: T[]) => void;
  searchNoResultsText?: string;
  searchPlaceholder?: string;
  selectedItems: T[];
  title: string;
}

export function ComboBox<T extends string>({
  badgeRenderer = renderBadge,
  buttonClassName,
  clearText = 'Clear filters',
  items,
  maxSelectedItemsToShow = 2,
  onItemsUpdate,
  searchNoResultsText = 'No results found',
  searchPlaceholder = 'Search...',
  selectedItems,
  title,
}: Readonly<ComboBoxProps<T>>) {
  return (
    <Popover>
      <PopoverTrigger asChild>
        <Button
          className={cn('h-8 border-dashed', buttonClassName)}
          size="sm"
          variant="outline"
        >
          <PlusCircle />
          {title}
          {selectedItems.length > 0 && (
            <>
              <Separator className="mx-2 h-4" orientation="vertical" />
              <Badge
                className="rounded-sm px-1 font-normal lg:hidden"
                variant="secondary"
              >
                {selectedItems.length}
              </Badge>
              <div className="hidden space-x-1 lg:flex">
                {selectedItems.length > maxSelectedItemsToShow ? (
                  <Badge
                    className="rounded-sm px-1 font-normal"
                    variant="secondary"
                  >
                    {selectedItems.length} selected
                  </Badge>
                ) : (
                  items
                    .filter(option => selectedItems.includes(option))
                    .map(badgeRenderer)
                )}
              </div>
            </>
          )}
        </Button>
      </PopoverTrigger>
      <PopoverContent className="max-w-2xl w-full p-0">
        <Command>
          <CommandInput className="h-9" placeholder={searchPlaceholder} />
          <CommandList>
            <CommandEmpty>{searchNoResultsText}</CommandEmpty>
            <CommandGroup>
              {items.map(item => (
                <CommandItem
                  key={item}
                  onSelect={() => {
                    const items = new Set(selectedItems);
                    if (items.has(item)) {
                      items.delete(item);
                    } else {
                      items.add(item);
                    }
                    onItemsUpdate(Array.from(items));
                  }}
                  value={item}
                >
                  {item}
                  <Check
                    className={cn(
                      'ml-auto',
                      selectedItems.includes(item) ? 'opacity-100' : 'opacity-0'
                    )}
                  />
                </CommandItem>
              ))}
            </CommandGroup>
            {selectedItems.length > 0 && (
              <>
                <CommandSeparator />
                <CommandGroup>
                  <CommandItem
                    className="justify-center text-center"
                    onSelect={() => onItemsUpdate([])}
                  >
                    {clearText}
                  </CommandItem>
                </CommandGroup>
              </>
            )}
          </CommandList>
        </Command>
      </PopoverContent>
    </Popover>
  );
}

function renderBadge<T extends string>(item: T) {
  return (
    <Badge
      className="rounded-sm px-1 font-normal"
      key={item}
      variant="secondary"
    >
      {item}
    </Badge>
  );
}
