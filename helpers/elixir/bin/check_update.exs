[dependency_name | credentials] = System.argv()

grouped_creds = Enum.reduce credentials, [], fn cred, acc ->
  if List.last(acc) == nil || List.last(acc)[:token] do
    acc = List.insert_at(acc, -1, %{ organization: cred })
  else
    { item, acc } = List.pop_at(acc, -1)
    item = Map.put(item, :token, cred)
    acc = List.insert_at(acc, -1, item)
  end
end

Enum.each grouped_creds, fn cred ->
  hexpm = Hex.Repo.get_repo("hexpm")
  repo = %{
    url: hexpm.url <> "/repos/#{cred.organization}",
    public_key: nil,
    auth_key: cred.token
  }

  Hex.Config.read()
  |> Hex.Config.read_repos()
  |> Map.put("hexpm:#{cred.organization}", repo)
  |> Hex.Config.update_repos()
end

# dependency atom
dependency = String.to_atom(dependency_name)

# Fetch dependencies that needs updating
{dependency_lock, rest_lock} = Map.split(Mix.Dep.Lock.read(), [dependency])

try do
  Mix.Dep.Fetcher.by_name([dependency_name], dependency_lock, rest_lock, [])

  # Check the dependency version in the new lock
  {updated_lock, _updated_rest_lock} = Map.split(Mix.Dep.Lock.read(), [dependency])

  version =
    updated_lock
    |> Map.get(dependency)
    |> elem(2)

  version = :erlang.term_to_binary({:ok, version})

  IO.write(:stdio, version)
rescue
  error in Hex.Version.InvalidRequirementError ->
    result = :erlang.term_to_binary({:error, "Invalid requirement: #{error.requirement}"})
    IO.write(:stdio, result)

  error in Mix.Error ->
    result = :erlang.term_to_binary({:error, "Dependency resolution failed: #{error.message}"})
    IO.write(:stdio, result)
end
