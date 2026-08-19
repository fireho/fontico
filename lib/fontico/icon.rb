# frozen_string_literal: true

module Fontico
  # One resolved entry from the manifest: the name templates use, plus where
  # it came from and the flags that decide which emitters accept it.
  Icon = Struct.new(:name, :provider, :slug, :multicolor, keyword_init: true) do
    def source     = "#{provider}/#{slug}"
    def local?     = provider == "local"
    def multicolor? = !!multicolor

    # Sprite symbol ids and the id-namespacing prefix both derive from here,
    # so a rename in the manifest moves them together.
    def key = name.tr(".", "-")
  end
end
