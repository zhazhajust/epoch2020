MODULE cfd_output

  USE cfd_common
  USE cfd_job_info
  USE shared_data
  USE version_data
  USE mpi

  IMPLICIT NONE

  SAVE

CONTAINS

  SUBROUTINE cfd_open_clobber(filename, step, time)

    CHARACTER(LEN=*), INTENT(IN) :: filename
    INTEGER, INTENT(IN) :: step
    DOUBLE PRECISION, INTENT(IN) :: time
    INTEGER(4) :: step4, endianness
    INTEGER :: errcode

    ! Set the block header
    block_header_size = max_string_len * 2_4 + soi + 2_4 * soi8

    ! Delete file and wait
    IF (cfd_rank .EQ. default_rank) &
        CALL MPI_FILE_DELETE(TRIM(filename), MPI_INFO_NULL, errcode)

    CALL MPI_BARRIER(cfd_comm, errcode)
    CALL MPI_FILE_OPEN(cfd_comm, TRIM(filename), cfd_mode, MPI_INFO_NULL, &
        cfd_filehandle, errcode)

    endianness = 16911887

    ! Currently no blocks written
    cfd_nblocks = 0

    IF (cfd_rank .EQ. default_rank) THEN
      ! Write the header
      CALL MPI_FILE_WRITE(cfd_filehandle, "CFD", 3, MPI_CHARACTER, &
          MPI_STATUS_IGNORE, errcode)

      ! This goes next so that stuff can be added to the global header without
      ! breaking everything
      CALL MPI_FILE_WRITE(cfd_filehandle, header_offset, 1, MPI_INTEGER4, &
          MPI_STATUS_IGNORE, errcode)
      CALL MPI_FILE_WRITE(cfd_filehandle, block_header_size, 1, MPI_INTEGER4, &
          MPI_STATUS_IGNORE, errcode)
      CALL MPI_FILE_WRITE(cfd_filehandle, cfd_version, 1, MPI_INTEGER4, &
          MPI_STATUS_IGNORE, errcode)
      CALL MPI_FILE_WRITE(cfd_filehandle, cfd_revision, 1, MPI_INTEGER4, &
          MPI_STATUS_IGNORE, errcode)
      CALL MPI_FILE_WRITE(cfd_filehandle, max_string_len, 1, MPI_INTEGER4, &
          MPI_STATUS_IGNORE, errcode)
      CALL MPI_FILE_WRITE(cfd_filehandle, cfd_nblocks, 1, MPI_INTEGER4, &
          MPI_STATUS_IGNORE, errcode)
      CALL MPI_FILE_WRITE(cfd_filehandle, endianness, 1, MPI_INTEGER4, &
          MPI_STATUS_IGNORE, errcode)
      CALL MPI_FILE_WRITE(cfd_filehandle, cfd_jobid%start_seconds, 1, &
          MPI_INTEGER4, MPI_STATUS_IGNORE, errcode)
      CALL MPI_FILE_WRITE(cfd_filehandle, cfd_jobid%start_milliseconds, 1, &
          MPI_INTEGER4, MPI_STATUS_IGNORE, errcode)
      step4 = INT(step, 4)
      CALL MPI_FILE_WRITE(cfd_filehandle, step4, 1, MPI_INTEGER4, &
          MPI_STATUS_IGNORE, errcode)
      CALL MPI_FILE_WRITE(cfd_filehandle, time, 1, MPI_DOUBLE_PRECISION, &
          MPI_STATUS_IGNORE, errcode)
    ENDIF

    ! Current displacement is just the header
    current_displacement = header_offset

  END SUBROUTINE cfd_open_clobber



  SUBROUTINE cfd_safe_write_string(string)

    CHARACTER(LEN=*), INTENT(IN) :: string
    CHARACTER(LEN=max_string_len) :: output
    INTEGER :: len_s, errcode

    len_s = LEN(string)

    IF (max_string_len .LT. len_s .AND. rank .EQ. default_rank) THEN
      PRINT*, '***WARNING***'
      PRINT*, 'Output string "' // string // '" has been truncated'
    ENDIF

    ! This subroutine expects that the record marker is in place and that
    ! the view is set correctly. Call it only on the node which is doing the
    ! writing. You still have to advance the file pointer yourself on all nodes

    output(1:MIN(max_string_len, len_s)) = string(1:MIN(max_string_len, len_s))

    ! If this isn't the full string length then tag in a ACHAR(0) to help
    ! With C++ string handling
    IF (len_s + 1 .LT. max_string_len) output(len_s+1:max_string_len) = ACHAR(0)

    CALL MPI_FILE_WRITE(cfd_filehandle, output, max_string_len, MPI_CHARACTER, &
        MPI_STATUS_IGNORE, errcode)

  END SUBROUTINE cfd_safe_write_string



  SUBROUTINE cfd_write_block_header(block_name, block_class, block_type, &
      block_length, block_md_length, rank_write)

    CHARACTER(LEN=*), INTENT(IN) :: block_name, block_class
    INTEGER(4), INTENT(IN) :: block_type
    INTEGER(8), INTENT(IN) :: block_length, block_md_length
    INTEGER, INTENT(IN) :: rank_write
    INTEGER :: errcode

    CALL MPI_FILE_SET_VIEW(cfd_filehandle, current_displacement, &
        MPI_CHARACTER, MPI_CHARACTER, "native", MPI_INFO_NULL, errcode)

    IF (cfd_rank .EQ. rank_write) THEN
      CALL cfd_safe_write_string(block_name)
      CALL cfd_safe_write_string(block_class)
    ENDIF
    current_displacement = current_displacement + 2 * max_string_len

    ! Write the block type
    CALL MPI_FILE_SET_VIEW(cfd_filehandle, current_displacement, &
        MPI_INTEGER4, MPI_INTEGER4, "native", MPI_INFO_NULL, errcode)

    IF (cfd_rank .EQ. rank_write) &
        CALL MPI_FILE_WRITE(cfd_filehandle, block_type, 1, MPI_INTEGER4, &
            MPI_STATUS_IGNORE, errcode)

    current_displacement = current_displacement + 4

    ! Write the block skip and metadata skip data
    CALL MPI_FILE_SET_VIEW(cfd_filehandle, current_displacement, &
        MPI_INTEGER8, MPI_INTEGER8, "native", MPI_INFO_NULL, errcode)

    IF (cfd_rank .EQ. rank_write) THEN
      CALL MPI_FILE_WRITE(cfd_filehandle, block_md_length, 1, MPI_INTEGER8, &
          MPI_STATUS_IGNORE, errcode)
      CALL MPI_FILE_WRITE(cfd_filehandle, block_length, 1, MPI_INTEGER8, &
          MPI_STATUS_IGNORE, errcode)
    ENDIF

    current_displacement = current_displacement + 2 * 8

    cfd_nblocks = cfd_nblocks + 1_4

  END SUBROUTINE cfd_write_block_header



  SUBROUTINE cfd_write_meshtype_header(meshtype, dim, sof, rank_write)

    ! MeshTypes (Meshes, fluid variables, multimat blocks etc)
    ! All have a common header, this is what writes that (although the content
    ! Of type will depend on what meshtype you're using)

    INTEGER(4), INTENT(IN) :: meshtype, dim
    INTEGER(8), INTENT(IN) :: sof
    INTEGER, INTENT(IN) :: rank_write
    INTEGER(4) :: sof4
    INTEGER :: errcode

    CALL MPI_FILE_SET_VIEW(cfd_filehandle, current_displacement, MPI_INTEGER4, &
        MPI_INTEGER4, "native", MPI_INFO_NULL, errcode)

    IF (cfd_rank .EQ. rank_write) THEN
      CALL MPI_FILE_WRITE(cfd_filehandle, meshtype, 1, MPI_INTEGER4, &
          MPI_STATUS_IGNORE, errcode)
      CALL MPI_FILE_WRITE(cfd_filehandle, dim, 1, MPI_INTEGER4, &
          MPI_STATUS_IGNORE, errcode)
      sof4 = INT(sof,4)
      CALL MPI_FILE_WRITE(cfd_filehandle, sof4, 1, MPI_INTEGER4, &
          MPI_STATUS_IGNORE, errcode)
    ENDIF

    current_displacement = current_displacement + meshtype_header_offset

  END SUBROUTINE cfd_write_meshtype_header



  SUBROUTINE cfd_write_snapshot_data(time, step, rank_write)

    REAL(8), INTENT(IN) :: time
    INTEGER, INTENT(IN) :: step, rank_write
    INTEGER(8) :: md_length
    INTEGER(4) :: step4
    INTEGER :: errcode

    md_length = soi + sof

    CALL cfd_write_block_header("Snapshot", "Snapshot", c_type_snapshot, &
        md_length, md_length, rank_write)

    CALL MPI_FILE_SET_VIEW(cfd_filehandle, current_displacement, MPI_INTEGER4, &
        MPI_INTEGER4, "native", MPI_INFO_NULL, errcode)

    IF (cfd_rank .EQ. rank_write) THEN
      step4 = INT(step, 4)
      CALL MPI_FILE_WRITE(cfd_filehandle, step4, 1, MPI_INTEGER4, &
          MPI_STATUS_IGNORE, errcode)
    ENDIF

    current_displacement = current_displacement + soi

    CALL MPI_FILE_SET_VIEW(cfd_filehandle, current_displacement, &
        MPI_DOUBLE_PRECISION, MPI_DOUBLE_PRECISION, "native", MPI_INFO_NULL, &
        errcode)

    IF (cfd_rank .EQ. rank_write) &
        CALL MPI_FILE_WRITE(cfd_filehandle, time, 1, MPI_DOUBLE_PRECISION, &
            MPI_STATUS_IGNORE, errcode)

    current_displacement = current_displacement + 8

  END SUBROUTINE cfd_write_snapshot_data



  SUBROUTINE cfd_write_job_info(restart_flag, sha1sum, rank_write)

    INTEGER, INTENT(IN) :: restart_flag
    CHARACTER(LEN=*), INTENT(IN) :: sha1sum
    INTEGER, INTENT(IN) :: rank_write
    INTEGER(8) :: md_length
    INTEGER(4) :: io_date, restart_flag4
    INTEGER :: errcode

    io_date = get_unix_time()

    md_length = 8 * soi + 4 * max_string_len

    CALL cfd_write_block_header(c_code_name, "Job_info", c_type_info, &
        md_length, md_length, rank_write)

    CALL MPI_FILE_SET_VIEW(cfd_filehandle, current_displacement, MPI_INTEGER4, &
        MPI_INTEGER4, "native", MPI_INFO_NULL, errcode)

    IF (cfd_rank .EQ. rank_write) THEN
      CALL MPI_FILE_WRITE(cfd_filehandle, c_code_io_version, 1, MPI_INTEGER4, &
          MPI_STATUS_IGNORE, errcode)
      CALL MPI_FILE_WRITE(cfd_filehandle, c_version, 1, MPI_INTEGER4, &
          MPI_STATUS_IGNORE, errcode)
      CALL MPI_FILE_WRITE(cfd_filehandle, c_revision, 1, MPI_INTEGER4, &
          MPI_STATUS_IGNORE, errcode)
    ENDIF

    current_displacement = current_displacement + 3 * soi

    CALL MPI_FILE_SET_VIEW(cfd_filehandle, current_displacement, &
        MPI_CHARACTER, MPI_CHARACTER, "native", MPI_INFO_NULL, errcode)

    IF (cfd_rank .EQ. rank_write) THEN
      CALL cfd_safe_write_string(c_commit_id)
      CALL cfd_safe_write_string(sha1sum)
      CALL cfd_safe_write_string(c_compile_machine)
      CALL cfd_safe_write_string(c_compile_flags)
    ENDIF

    current_displacement = current_displacement + 4 * max_string_len

    CALL MPI_FILE_SET_VIEW(cfd_filehandle, current_displacement, MPI_INTEGER4, &
        MPI_INTEGER4, "native", MPI_INFO_NULL, errcode)

    IF (cfd_rank .EQ. rank_write) THEN
      CALL MPI_FILE_WRITE(cfd_filehandle, defines, 1, MPI_INTEGER4, &
          MPI_STATUS_IGNORE, errcode)
      CALL MPI_FILE_WRITE(cfd_filehandle, c_compile_date, 1, MPI_INTEGER4, &
          MPI_STATUS_IGNORE, errcode)
      CALL MPI_FILE_WRITE(cfd_filehandle, run_date, 1, MPI_INTEGER4, &
          MPI_STATUS_IGNORE, errcode)
      CALL MPI_FILE_WRITE(cfd_filehandle, io_date, 1, MPI_INTEGER4, &
          MPI_STATUS_IGNORE, errcode)
      restart_flag4 = INT(restart_flag, 4)
      CALL MPI_FILE_WRITE(cfd_filehandle, restart_flag4, 1, MPI_INTEGER4, &
          MPI_STATUS_IGNORE, errcode)
    ENDIF

    current_displacement = current_displacement + 5 * soi

  END SUBROUTINE cfd_write_job_info



  SUBROUTINE cfd_write_stitched_vector(vector_name, vector_class, mesh_name, &
      mesh_class, name, class, rank_write)

    CHARACTER(LEN=*), INTENT(IN) :: vector_name, vector_class
    CHARACTER(LEN=*), INTENT(IN) :: mesh_name, mesh_class
    CHARACTER(LEN=*), DIMENSION(:), INTENT(IN) :: name, class
    INTEGER, INTENT(IN) :: rank_write
    INTEGER(8) :: md_length, block_length
    INTEGER(4) :: ndims
    INTEGER :: iloop, errcode

    ndims = INT(SIZE(name),4)

    md_length = 2 * max_string_len + soi
    block_length = md_length + ndims * 2 * max_string_len

    CALL cfd_write_block_header(vector_name, vector_class, &
        c_type_stitched_vector, block_length, md_length, rank_write)

    CALL MPI_FILE_SET_VIEW(cfd_filehandle, current_displacement, &
        MPI_CHARACTER, MPI_CHARACTER, "native", MPI_INFO_NULL, errcode)

    IF (cfd_rank .EQ. rank_write) THEN
      CALL cfd_safe_write_string(mesh_name)
      CALL cfd_safe_write_string(mesh_class)
    ENDIF

    current_displacement = current_displacement + 2 * max_string_len

    CALL MPI_FILE_SET_VIEW(cfd_filehandle, current_displacement, MPI_INTEGER4, &
        MPI_INTEGER4, "native", MPI_INFO_NULL, errcode)

    IF (cfd_rank .EQ. rank_write) &
        CALL MPI_FILE_WRITE(cfd_filehandle, ndims, 1, MPI_INTEGER4, &
            MPI_STATUS_IGNORE, errcode)

    current_displacement = current_displacement + soi

    CALL MPI_FILE_SET_VIEW(cfd_filehandle, current_displacement, &
        MPI_CHARACTER, MPI_CHARACTER, "native", MPI_INFO_NULL, errcode)

    IF (cfd_rank .EQ. rank_write) THEN
      DO iloop = 1, ndims
        CALL cfd_safe_write_string(name(iloop))
        CALL cfd_safe_write_string(class(iloop))
      ENDDO
    ENDIF

    current_displacement = current_displacement + 2 * ndims * max_string_len

  END SUBROUTINE cfd_write_stitched_vector



  SUBROUTINE cfd_write_stitched_magnitude(magn_name, magn_class, mesh_name, &
      mesh_class, name, class, rank_write)

    CHARACTER(LEN=*), INTENT(IN) :: magn_name, magn_class
    CHARACTER(LEN=*), INTENT(IN) :: mesh_name, mesh_class
    CHARACTER(LEN=*), DIMENSION(:), INTENT(IN) :: name, class
    INTEGER, INTENT(IN) :: rank_write
    INTEGER(8) :: md_length, block_length
    INTEGER(4) :: ndims
    INTEGER :: iloop, errcode

    ndims = INT(SIZE(name),4)

    md_length = 2 * max_string_len + soi
    block_length = md_length + ndims * 2 * max_string_len

    CALL cfd_write_block_header(magn_name, magn_class, &
        c_type_stitched_magnitude, block_length, md_length, rank_write)

    CALL MPI_FILE_SET_VIEW(cfd_filehandle, current_displacement, &
        MPI_CHARACTER, MPI_CHARACTER, "native", MPI_INFO_NULL, errcode)

    IF (cfd_rank .EQ. rank_write) THEN
      CALL cfd_safe_write_string(mesh_name)
      CALL cfd_safe_write_string(mesh_class)
    ENDIF

    current_displacement = current_displacement + 2 * max_string_len

    CALL MPI_FILE_SET_VIEW(cfd_filehandle, current_displacement, MPI_INTEGER4, &
        MPI_INTEGER4, "native", MPI_INFO_NULL, errcode)

    IF (cfd_rank .EQ. rank_write) &
        CALL MPI_FILE_WRITE(cfd_filehandle, ndims, 1, MPI_INTEGER4, &
            MPI_STATUS_IGNORE, errcode)

    current_displacement = current_displacement + soi

    CALL MPI_FILE_SET_VIEW(cfd_filehandle, current_displacement, &
        MPI_CHARACTER, MPI_CHARACTER, "native", MPI_INFO_NULL, errcode)

    IF (cfd_rank .EQ. rank_write) THEN
      DO iloop = 1, ndims
        CALL cfd_safe_write_string(name(iloop))
        CALL cfd_safe_write_string(class(iloop))
      ENDDO
    ENDIF

    current_displacement = current_displacement + 2 * ndims * max_string_len

  END SUBROUTINE cfd_write_stitched_magnitude



  SUBROUTINE cfd_write_real_constant(name, class, value, rank_write)

    CHARACTER(LEN=*), INTENT(IN) :: name, class
    REAL(num), INTENT(IN) :: value
    INTEGER, INTENT(IN) :: rank_write
    INTEGER(8) :: md_length
    INTEGER :: errcode

    md_length = sof

    CALL cfd_write_block_header(name, class, c_type_constant, md_length, &
        md_length, rank_write)
    CALL MPI_FILE_SET_VIEW(cfd_filehandle, current_displacement, mpireal, &
        mpireal, "native", MPI_INFO_NULL, errcode)

    IF (cfd_rank .EQ. rank_write) THEN
      CALL MPI_FILE_WRITE(cfd_filehandle, value, 1, mpireal, &
          MPI_STATUS_IGNORE, errcode)
    ENDIF

    current_displacement = current_displacement + sof

  END SUBROUTINE cfd_write_real_constant



  SUBROUTINE cfd_write_source_code(name, class, array, last, rank_write)

    CHARACTER(LEN=*), INTENT(IN) :: name, class
    CHARACTER(LEN=*), DIMENSION(:), INTENT(IN) :: array
    CHARACTER(LEN=*), INTENT(IN) :: last
    INTEGER, INTENT(IN) :: rank_write
    INTEGER(8) :: md_length, sz, len1, len2
    INTEGER :: i, errcode

    IF (cfd_rank .EQ. rank_write) THEN
      sz   = SIZE(array)
      len1 = LEN(array)
      len2 = LEN(last)
      md_length = sz*len1 + len2
    ENDIF

    CALL MPI_BCAST(md_length, 1, MPI_INTEGER8, 0, cfd_comm, errcode)

    CALL cfd_write_block_header(name, class, c_type_constant, md_length, &
        md_length, rank_write)
    CALL MPI_FILE_SET_VIEW(cfd_filehandle, current_displacement, &
        MPI_CHARACTER,  MPI_CHARACTER, "native", MPI_INFO_NULL, errcode)

    IF (cfd_rank .EQ. rank_write) THEN
      DO i = 1, sz
        CALL MPI_FILE_WRITE(cfd_filehandle, array(i), len1, &
            MPI_CHARACTER, MPI_STATUS_IGNORE, errcode)
      ENDDO
      CALL MPI_FILE_WRITE(cfd_filehandle, last, len2, &
          MPI_CHARACTER, MPI_STATUS_IGNORE, errcode)
    ENDIF

    current_displacement = current_displacement + md_length

  END SUBROUTINE cfd_write_source_code



  SUBROUTINE cfd_write_1d_integer_array(name, class, values, rank_write)

    CHARACTER(LEN=*), INTENT(IN) :: name, class
    INTEGER, DIMENSION(:), INTENT(IN) :: values
    INTEGER, INTENT(IN) :: rank_write
    INTEGER(8) :: md_length
    INTEGER(4) :: sz
    INTEGER :: errcode

    md_length = 3 * soi

    CALL cfd_write_block_header(name, class, c_type_integerarray, md_length, &
        md_length, rank_write)
    CALL MPI_FILE_SET_VIEW(cfd_filehandle, current_displacement, MPI_INTEGER4, &
        MPI_INTEGER4, "native", MPI_INFO_NULL, errcode)

    IF (cfd_rank .EQ. rank_write) THEN
      ! 1D
      CALL MPI_FILE_WRITE(cfd_filehandle, 1, c_dimension_1d, MPI_INTEGER4, &
          MPI_STATUS_IGNORE, errcode)
      ! INTEGER kind
      sz = KIND(values)
      CALL MPI_FILE_WRITE(cfd_filehandle, 1, sz, MPI_INTEGER4, &
          MPI_STATUS_IGNORE, errcode)
      ! Size of array
      CALL MPI_FILE_WRITE(cfd_filehandle, 1, SIZE(values), MPI_INTEGER4, &
          MPI_STATUS_IGNORE, errcode)
      ! Actual array
      CALL MPI_FILE_WRITE(cfd_filehandle, values, SIZE(values), MPI_INTEGER4, &
          MPI_STATUS_IGNORE, errcode)
    ENDIF

    current_displacement = current_displacement + md_length

  END SUBROUTINE cfd_write_1d_integer_array



  SUBROUTINE cfd_write_visit_expression(expression_name, expression_class, &
      expression)

    CHARACTER(LEN=*), DIMENSION(:), INTENT(IN) :: expression_name
    CHARACTER(LEN=*), DIMENSION(:), INTENT(IN) :: expression_class, expression

    PRINT *, LEN(expression(1)), LEN(expression(2))

  END SUBROUTINE cfd_write_visit_expression

END MODULE cfd_output