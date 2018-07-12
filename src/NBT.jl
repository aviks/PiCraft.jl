# ParseNBT files and import/export .schematic files
#
# NBT is a file format used by Minecraft to store data. https://minecraft.gamepedia.com/NBT_format
# A specification was provided by Notch which can be accessed using archive.org
# http://web.archive.org/web/20110723210920/http://www.minecraft.net/docs/NBT.txt
#
# The format of a Named Tag is :
#     byte tagType
#     TAG_String name
#     [payload]
#
# [payload] depends on the type of Named Tag.
# Name Tags are Named Tags without the name, [payload] is the same
#
# NBT files are mostly GZip Compressed however there are places where unzipped
# files are used.
# Use the GZip.jl Package to read/write GZip streams: https://github.com/JuliaIO/GZip.jl
#
# We don't differentiate between Named and Nameless files. Nameless Tags are
# Named Tags with an empty string as their name.

abstract type Tag end

struct TAG_End <: Tag
end

struct TAG_Byte <: Tag
    name::String
    payload::Int8
end

struct TAG_Short <: Tag
    name::String
    payload::Int16
end

struct TAG_Int <: Tag
    name::String
    payload::Int32
end

struct TAG_Long <: Tag
    name::String
    payload::Int64
end

struct TAG_Float <: Tag
    name::String
    payload::Float32
end

struct TAG_Double <: Tag
    name::String
    payload::Float64
end

struct TAG_Byte_Array <: Tag
    name::String
    payload::Array{UInt8, 1}
end

struct TAG_String <: Tag
    name::String
    payload::String
end

struct TAG_List <: Tag
    name::String
    tagId::UInt8
    payload::Array{Tag, 1}
end

struct TAG_Compound <: Tag
    name::String
    payload::Array{Tag, 1}
end

struct TAG_Int_Array <: Tag
    name::String
    payload::Array{Int32, 1}
end

struct TAG_Long_Array <: Tag
    name::String
    payload::Array{Int64, 1}
end

tagDict = Dict(0 => TAG_End, 1 => TAG_Byte, 2 => TAG_Short, 3 => TAG_Int, 4 => TAG_Long,
               5 => TAG_Float, 6 => TAG_Double, 7 => TAG_Byte_Array, 8 => TAG_String,
               9 => TAG_List, 10 => TAG_Compound, 11 => TAG_Int_Array, 12 => TAG_Long_Array)

tagKeyDict = Dict(TAG_End => 0, TAG_Byte => 1, TAG_Short = 2, TAG_Int = 3, TAG_Long = 4,
                  TAG_Float => 5, TAG_Double => 6, TAG_Byte_Array => 7, TAG_String = 8
                  TAG_List => 9, TAG_Compound => 10, TAG_Int_Array => 11, TAG_Long_Array => 12)

function readTAG(stream::IO, tagId = -1)
    named = tagId == -1 ? true:false
    if tagId == -1
        tagId = read(stream, UInt8)
    end
    if !(tagId in 0:12)
        error("Unknown TagType")
    end

    if tagId == 0
        return TAG_End()
    end

    name = ""
    if named
        nameLength = bswap(read(stream, UInt16))
        for i in 1:nameLength
            name *= string(Char(read(stream, UInt8)))
        end
    end

    if tagId in 1:6
        payload = bswap(read(stream, fieldtype(tagDict[tagId], :payload)))
    elseif tagId in [7, 11, 12]
        length = bswap(read(stream, Int32))
        payload = fieldtype(tagDict[tagId], :payload)()
        for i in 1:length
            push!(payload, bswap(read(stream, eltype(fieldtype(tagDict[tagId], :payload)))))
        end
    elseif tagId == 8
        length = bswap(read(stream, UInt16))
        payload = ""
        for i in 1:length
            payload *= string(Char(read(stream, UInt8)))
        end
    elseif tagId == 9
        tagId2 = read(stream, UInt8)
        if !(tagId2 in 0:12)
            error("Unknown tagId")
        end

        tags = bswap(read(stream, UInt32))
        payload = Array{Tag, 1}()
        for i in 1:tags
            x = readTAG(stream, tagId2)
            println(x)
            push!(payload, x)
        end
        return TAG_List(name, tagId2, payload)
    elseif tagId == 10
        payload = Array{Tag, 1}()
        tag = readTAG(stream, -1)
        while typeof(tag) != TAG_End
            push!(payload, tag)
            tag = readTAG(stream, -1)
        end
    end
    return tagDict[tagId](name, payload)
end

function printTAG(tag::Tag, stream::IO = STDOUT, tabDepth = 0)
    if typeof(tag) in  [TAG_Byte, TAG_Short, TAG_Int, TAG_Long, TAG_Float, TAG_Double, TAG_String]
        println(stream, "\t"^tabDepth, typeof(tag), " : ", "\""*tag.name*"\"", " = ", tag.payload)
    elseif typeof(tag) == TAG_List
        println(stream, "\t"^tabDepth, "TAG_List : ", tagDict[tag.tagId], " : ", "\""*tag.name*"\"", "(", length(tag.payload), " entries)")
        for t in tag.payload
            printTAG(t, stream, tabDepth + 1)
        end
    elseif typeof(tag) == TAG_Compound
        println(stream, "\t"^tabDepth, "TAG_Compound : ","\""*tag.name*"\"", " , (", length(tag.payload), " entries)")
        for t in tag.payload
            printTAG(t, stream, tabDepth + 1)
        end
    else
        println(stream, "\t"^tabDepth, typeof(tag),"\""*tag.name*"\" = ", tag.payload)
    end
end


function parseNBT(istream::IO, ostream::IO = STDOUT)
while !(eof(istream))
    printTAG(readTAG(istream), ostream, 0)
end
end

function importSchematic(istream::IO, p::Tuple{Real, Real, Real} = getPos())
    schematic = readTAG(istream)
    if schematic.name != "Schematic"
        error("$istream is not a Schematic file.")
    end

    Height, Length, Width = 0, 0, 0
    BlockData = []
    BlockIds = []

    for tag in schematic.payload
        if tag.name == "Height"
            Height = tag.payload
        elseif tag.name == "Length"
            Length = tag.payload
        elseif tag.name == "Width"
            Width = tag.payload
        elseif tag.name == "Blocks" && typeof(tag) == TAG_Byte_Array
            BlockIds = tag.payload
        elseif tag.name == "Data" && typeof(tag) == TAG_Byte_Array
            BlockData = tag.payload
        end
    end

    # Coordinates in schematics range from (0,0,0) to (Width-1, Height-1, Length-1).
    # Blocks are sorted by Height then Length and then Width
    for Y in 0:(Height - 1)
        for X in 0:(Width - 1)
            for Z in 0:(Length - 1)
                i = (Y*Length + Z)*Width + X + 1
                setBlock(p .+ (X, Y, Z), Block(BlockIds[i], BlockData[i]))
            end
        end
    end
end