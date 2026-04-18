%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: [
          ~r"/_build/",
          ~r"/deps/",
          ~r"\.pb\.ex$",
          ~r"/lib/espex/proto/"
        ]
      },
      strict: true,
      color: true,
      checks: %{
        enabled: [
          {Credo.Check.Design.TagTODO, false}
        ]
      }
    }
  ]
}
