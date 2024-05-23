!Crown Copyright 2012 AWE.
!
! This file is part of CloverLeaf.
!
! CloverLeaf is free software: you can redistribute it and/or modify it under 
! the terms of the GNU General Public License as published by the 
! Free Software Foundation, either version 3 of the License, or (at your option) 
! any later version.
!
! CloverLeaf is distributed in the hope that it will be useful, but 
! WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or 
! FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more 
! details.
!
! You should have received a copy of the GNU General Public License along with 
! CloverLeaf. If not, see http://www.gnu.org/licenses/.

!>  @brief Communication Utilities
!>  @author Wayne Gaudin
!>  @details Contains all utilities required to run CloverLeaf in a distributed
!>  environment, including initialisation, mesh decompostion, reductions and
!>  halo exchange using explicit buffers.
!>
!>  Note the halo exchange is currently coded as simply as possible and no 
!>  optimisations have been implemented, such as post receives before sends or packing
!>  buffers with multiple data fields. This is intentional so the effect of these
!>  optimisations can be measured on large systems, as and when they are added.
!>
!>  Even without these modifications CloverLeaf weak scales well on moderately sized
!>  systems of the order of 10K cores.

MODULE clover_module

  USE data_module
  USE definitions_module
  USE MPI
  USE iso_c_binding
  USE mpi_interface

  IMPLICIT NONE

CONTAINS

  SUBROUTINE clover_barrier

    integer(c_int) :: err

    CALL my_MPI_Barrier(MPI_COMM_WORLD,err)

  END SUBROUTINE clover_barrier

  SUBROUTINE clover_abort

    integer(c_int) :: ierr,err

    CALL my_MPI_Abort(MPI_COMM_WORLD,ierr,err)

  END SUBROUTINE clover_abort

  SUBROUTINE clover_finalize

    integer(c_int) :: err

    CLOSE(g_out)
    CALL FLUSH(0)
    CALL FLUSH(6)
    CALL FLUSH(g_out)
    CALL MPI_FINALIZE(err)

  END SUBROUTINE clover_finalize

  SUBROUTINE clover_init_comms

    IMPLICIT NONE

    integer(c_int) :: err,rank,size
    integer(c_int) :: c_mpi_comm
    integer(c_int) :: c_mpi_comm_slf

    rank=0
    size=1

    CALL MPI_INIT(err)

    ! I added
    c_mpi_comm = MPI_COMM_WORLD
    c_mpi_comm_slf = MPI_COMM_SELF
    CALL my_MPI_Init(c_mpi_comm, c_mpi_comm_slf, err)
    
    ! substituted this with my own function
    call my_MPI_Comm_rank(c_mpi_comm, rank, err)
    ! CALL MPI_COMM_RANK(MPI_COMM_WORLD,rank,err)

    CALL my_MPI_Comm_size(MPI_COMM_WORLD,size,err)

    parallel%parallel=.TRUE.
    parallel%task=rank

    IF(rank.EQ.0) THEN
      parallel%boss=.TRUE.
    ENDIF

    parallel%boss_task=0
    parallel%max_task=size

  END SUBROUTINE clover_init_comms

  SUBROUTINE clover_get_num_chunks(count)

    IMPLICIT NONE

    integer(c_int) :: count

    ! Should be changed so there can be more than one chunk per mpi task

    count=parallel%max_task

  END SUBROUTINE clover_get_num_chunks

  SUBROUTINE clover_decompose(x_cells,y_cells,left,right,bottom,top)

    ! This decomposes the mesh into a number of chunks.
    ! The number of chunks may be a multiple of the number of mpi tasks
    ! Doesn't always return the best split if there are few factors
    ! All factors need to be stored and the best picked. But its ok for now

    IMPLICIT NONE

    integer(c_int) :: x_cells,y_cells,left,right,top,bottom
    integer(c_int) :: c,delta_x,delta_y

    REAL(KIND=8) :: mesh_ratio,factor_x,factor_y
    integer(c_int)  :: chunk_x,chunk_y,mod_x,mod_y,split_found

    integer(c_int)  :: cx,cy,cnk,add_x,add_y,add_x_prev,add_y_prev

    ! 2D Decomposition of the mesh

    mesh_ratio=real(x_cells)/real(y_cells)

    chunk_x=number_of_chunks
    chunk_y=1

    split_found=0 ! Used to detect 1D decomposition
    DO c=1,number_of_chunks
      IF (MOD(number_of_chunks,c).EQ.0) THEN
        factor_x=number_of_chunks/real(c)
        factor_y=c
        !Compare the factor ratio with the mesh ratio
        IF(factor_x/factor_y.LE.mesh_ratio) THEN
          chunk_y=c
          chunk_x=number_of_chunks/c
          split_found=1
          EXIT
        ENDIF
      ENDIF
    ENDDO

    IF(split_found.EQ.0.OR.chunk_y.EQ.number_of_chunks) THEN ! Prime number or 1D decomp detected
      IF(mesh_ratio.GE.1.0) THEN
        chunk_x=number_of_chunks
        chunk_y=1
      ELSE
        chunk_x=1
        chunk_y=number_of_chunks
      ENDIF
    ENDIF

    delta_x=x_cells/chunk_x
    delta_y=y_cells/chunk_y
    mod_x=MOD(x_cells,chunk_x)
    mod_y=MOD(y_cells,chunk_y)

    ! Set up chunk mesh ranges and chunk connectivity

    add_x_prev=0
    add_y_prev=0
    cnk=1
    DO cy=1,chunk_y
      DO cx=1,chunk_x
        add_x=0
        add_y=0
        IF(cx.LE.mod_x)add_x=1
        IF(cy.LE.mod_y)add_y=1

        IF (cnk .EQ. parallel%task+1) THEN
          left   = (cx-1)*delta_x+1+add_x_prev
          right  = left+delta_x-1+add_x
          bottom = (cy-1)*delta_y+1+add_y_prev
          top    = bottom+delta_y-1+add_y

          chunk%chunk_neighbours(chunk_left)=chunk_x*(cy-1)+cx-1
          chunk%chunk_neighbours(chunk_right)=chunk_x*(cy-1)+cx+1
          chunk%chunk_neighbours(chunk_bottom)=chunk_x*(cy-2)+cx
          chunk%chunk_neighbours(chunk_top)=chunk_x*(cy)+cx

          IF(cx.EQ.1)       chunk%chunk_neighbours(chunk_left)=external_face
          IF(cx.EQ.chunk_x) chunk%chunk_neighbours(chunk_right)=external_face
          IF(cy.EQ.1)       chunk%chunk_neighbours(chunk_bottom)=external_face
          IF(cy.EQ.chunk_y) chunk%chunk_neighbours(chunk_top)=external_face
        ENDIF

        IF(cx.LE.mod_x)add_x_prev=add_x_prev+1
        cnk=cnk+1
      ENDDO
      add_x_prev=0
      IF(cy.LE.mod_y)add_y_prev=add_y_prev+1
    ENDDO

    IF(parallel%boss)THEN
      WRITE(g_out,*)
      WRITE(g_out,*)"Mesh ratio of ",mesh_ratio
      WRITE(g_out,*)"Decomposing the mesh into ",chunk_x," by ",chunk_y," chunks"
      WRITE(g_out,*)"Decomposing the chunk with ",tiles_per_chunk," tiles"
      WRITE(g_out,*)
    ENDIF

  END SUBROUTINE clover_decompose


  SUBROUTINE clover_tile_decompose(chunk_x_cells, chunk_y_cells)

    IMPLICIT NONE

    integer(c_int) :: chunk_x_cells, chunk_y_cells

    integer(c_int) :: chunk_mesh_ratio, tile_x, tile_y, split_found, factor_x, factor_y, t
    integer(c_int) :: chunk_delta_x, chunk_delta_y,  chunk_mod_x,  chunk_mod_y
    integer(c_int) :: add_x_prev, add_y_prev, tile, tx, ty, add_x, add_y, left, right, top, bottom

    chunk_mesh_ratio=real(chunk_x_cells)/real(chunk_y_cells)

    tile_x=tiles_per_chunk
    tile_y=1

    split_found=0 ! Used to detect 1D decomposition
    DO t=1,tiles_per_chunk
      IF (MOD(tiles_per_chunk,t).EQ.0) THEN
        factor_x=tiles_per_chunk/real(t)
        factor_y=t
        !Compare the factor ratio with the mesh ratio
        IF(factor_x/factor_y.LE.chunk_mesh_ratio) THEN
          tile_y=t
          tile_x=tiles_per_chunk/t
          split_found=1
          EXIT
        ENDIF
      ENDIF
    ENDDO

    IF(split_found.EQ.0.OR.tile_y.EQ.tiles_per_chunk) THEN ! Prime number or 1D decomp detected
      IF(chunk_mesh_ratio.GE.1.0) THEN
        tile_x=tiles_per_chunk
        tile_y=1
      ELSE
        tile_x=1
        tile_y=tiles_per_chunk
      ENDIF
    ENDIF

    chunk_delta_x=chunk_x_cells/tile_x
    chunk_delta_y=chunk_y_cells/tile_y
    chunk_mod_x=MOD(chunk_x_cells,tile_x)
    chunk_mod_y=MOD(chunk_y_cells,tile_y)


    add_x_prev=0
    add_y_prev=0
    tile=1
    DO ty=1,tile_y
      DO tx=1,tile_x
        add_x=0
        add_y=0
        IF(tx.LE.chunk_mod_x)add_x=1
        IF(ty.LE.chunk_mod_y)add_y=1

        left   = chunk%left+(tx-1)*chunk_delta_x+add_x_prev
        right  = left+chunk_delta_x-1+add_x
        bottom = chunk%bottom+(ty-1)*chunk_delta_y+add_y_prev
        top    = bottom+chunk_delta_y-1+add_y

        chunk%tiles(tile)%tile_neighbours(tile_left)=tile_x*(ty-1)+tx-1
        chunk%tiles(tile)%tile_neighbours(tile_right)=tile_x*(ty-1)+tx+1
        chunk%tiles(tile)%tile_neighbours(tile_bottom)=tile_x*(ty-2)+tx
        chunk%tiles(tile)%tile_neighbours(tile_top)=tile_x*(ty)+tx


        !initial set the external tile mask to 0 for each tile
        chunk%tiles(tile)%external_tile_mask = 0

        IF(tx.EQ.1) THEN
          chunk%tiles(tile)%tile_neighbours(tile_left)=external_tile
          chunk%tiles(tile)%external_tile_mask(TILE_LEFT) = 1
        ENDIF
        IF(tx.EQ.tile_x) THEN
          chunk%tiles(tile)%tile_neighbours(tile_right)=external_tile
          chunk%tiles(tile)%external_tile_mask(TILE_RIGHT) = 1
        ENDIF
        IF(ty.EQ.1) THEN
          chunk%tiles(tile)%tile_neighbours(tile_bottom)=external_tile
          chunk%tiles(tile)%external_tile_mask(TILE_BOTTOM) = 1
        ENDIF
        IF(ty.EQ.tile_y) THEN
          chunk%tiles(tile)%tile_neighbours(tile_top)=external_tile
          chunk%tiles(tile)%external_tile_mask(TILE_TOP) = 1
        ENDIF

        IF(tx.LE.chunk_mod_x)add_x_prev=add_x_prev+1

        chunk%tiles(tile)%t_xmin = 1
        chunk%tiles(tile)%t_xmax = right - left + 1
        chunk%tiles(tile)%t_ymin = 1
        chunk%tiles(tile)%t_ymax = top - bottom + 1

            
        chunk%tiles(tile)%t_left = left
        chunk%tiles(tile)%t_right = right
        chunk%tiles(tile)%t_top = top
        chunk%tiles(tile)%t_bottom = bottom

        tile=tile+1
      ENDDO
      add_x_prev=0
      IF(ty.LE.chunk_mod_y)add_y_prev=add_y_prev+1
    ENDDO


  END SUBROUTINE clover_tile_decompose



  SUBROUTINE clover_allocate_buffers()

    IMPLICIT NONE

  
    ! Unallocated buffers for external boundaries caused issues on some systems so they are now
    !  all allocated
    IF(parallel%task.EQ.chunk%task)THEN
      !IF(chunk%chunk_neighbours(chunk_left).NE.external_face) THEN
      ALLOCATE(chunk%left_snd_buffer(10*2*(chunk%y_max+5)))
      ALLOCATE(chunk%left_rcv_buffer(10*2*(chunk%y_max+5)))
      !ENDIF
      !IF(chunk%chunk_neighbours(chunk_right).NE.external_face) THEN
      ALLOCATE(chunk%right_snd_buffer(10*2*(chunk%y_max+5)))
      ALLOCATE(chunk%right_rcv_buffer(10*2*(chunk%y_max+5)))
      !ENDIF
      !IF(chunk%chunk_neighbours(chunk_bottom).NE.external_face) THEN
      ALLOCATE(chunk%bottom_snd_buffer(10*2*(chunk%x_max+5)))
      ALLOCATE(chunk%bottom_rcv_buffer(10*2*(chunk%x_max+5)))
      !ENDIF
      !IF(chunk%chunk_neighbours(chunk_top).NE.external_face) THEN
      ALLOCATE(chunk%top_snd_buffer(10*2*(chunk%x_max+5)))
      ALLOCATE(chunk%top_rcv_buffer(10*2*(chunk%x_max+5)))
      !ENDIF
    ENDIF

  END SUBROUTINE clover_allocate_buffers

  SUBROUTINE clover_exchange(fields,depth)

    IMPLICIT NONE

    integer(c_int)      :: fields(:),depth, tile, cnk
    integer(c_int)      :: left_right_offset(15),bottom_top_offset(15)
    integer(c_int)      :: request(4)
    integer(c_int)      :: message_count,err
    integer(c_int)      :: status(MPI_STATUS_SIZE,4)
    integer(c_int)      :: end_pack_index_left_right, end_pack_index_bottom_top,field

    ! Assuming 1 patch per task, this will be changed
    request=0
    message_count=0

    cnk = 1

    end_pack_index_left_right=0
    end_pack_index_bottom_top=0
    DO field=1,15
      IF(fields(field).EQ.1) THEN
        left_right_offset(field)=end_pack_index_left_right
        bottom_top_offset(field)=end_pack_index_bottom_top
        end_pack_index_left_right=end_pack_index_left_right+depth*(chunk%y_max+5)
        end_pack_index_bottom_top=end_pack_index_bottom_top+depth*(chunk%x_max+5)
      ENDIF
    ENDDO

    IF(chunk%chunk_neighbours(chunk_left).NE.external_face) THEN
      ! do left exchanges
      ! Find left hand tiles
      DO tile=1,tiles_per_chunk
        IF(chunk%tiles(tile)%external_tile_mask(TILE_LEFT).EQ.1) THEN
          CALL clover_pack_left(tile, fields, depth, left_right_offset)
        ENDIF
      ENDDO

      !send and recv messagse to the left
      CALL clover_send_recv_message_left(chunk%left_snd_buffer,                      &
        chunk%left_rcv_buffer,                      &
        end_pack_index_left_right,                    &
        1, 2,                                               &
        request(message_count+1), request(message_count+2))
      message_count = message_count + 2
    ENDIF

    IF(chunk%chunk_neighbours(chunk_right).NE.external_face) THEN
      ! do right exchanges
      DO tile=1,tiles_per_chunk
        IF(chunk%tiles(tile)%external_tile_mask(TILE_RIGHT).EQ.1) THEN
          CALL clover_pack_right(tile, fields, depth, left_right_offset)
        ENDIF
      ENDDO

      !send message to the right
      CALL clover_send_recv_message_right(chunk%right_snd_buffer,                     &
        chunk%right_rcv_buffer,                     &
        end_pack_index_left_right,                    &
        2, 1,                                               &
        request(message_count+1), request(message_count+2))
      message_count = message_count + 2
    ENDIF

    !make a call to wait / sync
    ! CALL MPI_WAITALL(message_count,request,status,err)
    CALL my_MPI_Waitall(message_count,request,status,err)

    !unpack in left direction
    IF(chunk%chunk_neighbours(chunk_left).NE.external_face) THEN
      DO tile=1,tiles_per_chunk
        IF(chunk%tiles(tile)%external_tile_mask(TILE_LEFT).EQ.1) THEN
          CALL clover_unpack_left(fields, tile, depth,                      &
            chunk%left_rcv_buffer,             &
            left_right_offset)
        ENDIF
      ENDDO
    ENDIF


    !unpack in right direction
    IF(chunk%chunk_neighbours(chunk_right).NE.external_face) THEN
      DO tile=1,tiles_per_chunk
        IF(chunk%tiles(tile)%external_tile_mask(TILE_RIGHT).EQ.1) THEN
          CALL clover_unpack_right(fields, tile, depth,                     &
            chunk%right_rcv_buffer,           &
            left_right_offset)
        ENDIF
      ENDDO
    ENDIF

    message_count = 0
    request = 0

    IF(chunk%chunk_neighbours(chunk_bottom).NE.external_face) THEN
      ! do bottom exchanges
      DO tile=1,tiles_per_chunk
        IF(chunk%tiles(tile)%external_tile_mask(TILE_BOTTOM).EQ.1) THEN
          CALL clover_pack_bottom(tile, fields, depth, bottom_top_offset)
        ENDIF
      ENDDO

      !send message downwards
      CALL clover_send_recv_message_bottom(chunk%bottom_snd_buffer,                     &
        chunk%bottom_rcv_buffer,                     &
        end_pack_index_bottom_top,                     &
        3, 4,                                                &
        request(message_count+1), request(message_count+2))
      message_count = message_count + 2
    ENDIF

    IF(chunk%chunk_neighbours(chunk_top).NE.external_face) THEN
      ! do top exchanges
      DO tile=1,tiles_per_chunk
        IF(chunk%tiles(tile)%external_tile_mask(TILE_TOP).EQ.1) THEN
          CALL clover_pack_top(tile, fields, depth, bottom_top_offset)
        ENDIF
      ENDDO

      !send message upwards
      CALL clover_send_recv_message_top(chunk%top_snd_buffer,                           &
        chunk%top_rcv_buffer,                           &
        end_pack_index_bottom_top,                        &
        4, 3,                                                   &
        request(message_count+1), request(message_count+2))
      message_count = message_count + 2
    ENDIF

    !need to make a call to wait / sync
    ! CALL MPI_WAITALL(message_count,request,status,err)
    CALL my_MPI_Waitall(message_count,request,status,err)

    !unpack in top direction
    IF( chunk%chunk_neighbours(chunk_top).NE.external_face ) THEN
      DO tile=1,tiles_per_chunk
        IF(chunk%tiles(tile)%external_tile_mask(TILE_TOP).EQ.1) THEN
          CALL clover_unpack_top(fields, tile, depth,                       &
            chunk%top_rcv_buffer,               &
            bottom_top_offset)
        ENDIF
      ENDDO
    ENDIF

    !unpack in bottom direction
    IF(chunk%chunk_neighbours(chunk_bottom).NE.external_face) THEN
      DO tile=1,tiles_per_chunk
        IF(chunk%tiles(tile)%external_tile_mask(TILE_BOTTOM).EQ.1) THEN
          CALL clover_unpack_bottom(fields, tile, depth,                   &
            chunk%bottom_rcv_buffer,         &
            bottom_top_offset)
        ENDIF
      ENDDO
    ENDIF

  END SUBROUTINE clover_exchange

  SUBROUTINE clover_pack_left(tile, fields, depth, left_right_offset)

    USE pack_kernel_module

    IMPLICIT NONE

    integer(c_int)      :: fields(:),depth, tile, t_offset
    integer(c_int)      :: left_right_offset(:)
  
  
    t_offset = (chunk%tiles(tile)%t_bottom - chunk%bottom)*depth
    
    IF(use_fortran_kernels) THEN
      IF(fields(FIELD_DENSITY0).EQ.1) THEN
        CALL clover_pack_message_left(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%density0,                 &
          chunk%left_snd_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_DENSITY0)+t_offset)

      ENDIF
      IF(fields(FIELD_DENSITY1).EQ.1) THEN
        CALL clover_pack_message_left(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%density1,                 &
          chunk%left_snd_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_DENSITY1)+t_offset)

      ENDIF
      IF(fields(FIELD_ENERGY0).EQ.1) THEN
        CALL clover_pack_message_left(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%energy0,                  &
          chunk%left_snd_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_ENERGY0)+t_offset)

      ENDIF
      IF(fields(FIELD_ENERGY1).EQ.1) THEN
        CALL clover_pack_message_left(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%energy1,                  &
          chunk%left_snd_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_ENERGY1)+t_offset)

      ENDIF
      IF(fields(FIELD_PRESSURE).EQ.1) THEN
        CALL clover_pack_message_left(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%pressure,                 &
          chunk%left_snd_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_PRESSURE)+t_offset)

      ENDIF
      IF(fields(FIELD_VISCOSITY).EQ.1) THEN
        CALL clover_pack_message_left(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%viscosity,                &
          chunk%left_snd_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_VISCOSITY)+t_offset)

      ENDIF
      IF(fields(FIELD_SOUNDSPEED).EQ.1) THEN
        CALL clover_pack_message_left(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%soundspeed,               &
          chunk%left_snd_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_SOUNDSPEED)+t_offset)

      ENDIF
      IF(fields(FIELD_XVEL0).EQ.1) THEN
        CALL clover_pack_message_left(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%xvel0,                    &
          chunk%left_snd_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          left_right_offset(FIELD_XVEL0)+t_offset)

      ENDIF
      IF(fields(FIELD_XVEL1).EQ.1) THEN
        CALL clover_pack_message_left(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%xvel1,                    &
          chunk%left_snd_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          left_right_offset(FIELD_XVEL1)+t_offset)

      ENDIF
      IF(fields(FIELD_YVEL0).EQ.1) THEN
        CALL clover_pack_message_left(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%yvel0,                    &
          chunk%left_snd_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          left_right_offset(FIELD_YVEL0)+t_offset)

      ENDIF
      IF(fields(FIELD_YVEL1).EQ.1) THEN
        CALL clover_pack_message_left(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%yvel1,                    &
          chunk%left_snd_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          left_right_offset(FIELD_YVEL1)+t_offset)

      ENDIF
      IF(fields(FIELD_VOL_FLUX_X).EQ.1) THEN
        CALL clover_pack_message_left(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%vol_flux_x,               &
          chunk%left_snd_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, X_FACE_DATA,                           &
          left_right_offset(FIELD_VOL_FLUX_X)+t_offset)

      ENDIF
      IF(fields(FIELD_VOL_FLUX_Y).EQ.1) THEN
        CALL clover_pack_message_left(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%vol_flux_y,               &
          chunk%left_snd_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, Y_FACE_DATA,                           &
          left_right_offset(FIELD_VOL_FLUX_Y)+t_offset)

      ENDIF
      IF(fields(FIELD_MASS_FLUX_X).EQ.1) THEN
        CALL clover_pack_message_left(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%mass_flux_x,              &
          chunk%left_snd_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, X_FACE_DATA,                           &
          left_right_offset(FIELD_MASS_FLUX_X)+t_offset)

      ENDIF
      IF(fields(FIELD_MASS_FLUX_Y).EQ.1) THEN
        CALL clover_pack_message_left(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%mass_flux_y,              &
          chunk%left_snd_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, Y_FACE_DATA,                           &
          left_right_offset(FIELD_MASS_FLUX_Y)+t_offset)

      ENDIF
  
    ELSEIF(use_C_kernels) THEN
      IF(fields(FIELD_DENSITY0).EQ.1) THEN
        CALL clover_pack_message_left_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%density0,                 &
          chunk%left_snd_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_DENSITY0)+t_offset)
    
      ENDIF
      IF(fields(FIELD_DENSITY1).EQ.1) THEN
        CALL clover_pack_message_left_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%density1,                 &
          chunk%left_snd_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_DENSITY1)+t_offset)
    
      ENDIF
      IF(fields(FIELD_ENERGY0).EQ.1) THEN
        CALL clover_pack_message_left_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%energy0,                  &
          chunk%left_snd_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_ENERGY0)+t_offset)
   
      ENDIF
      IF(fields(FIELD_ENERGY1).EQ.1) THEN
        CALL clover_pack_message_left_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%energy1,                  &
          chunk%left_snd_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_ENERGY1)+t_offset)
    
      ENDIF
      IF(fields(FIELD_PRESSURE).EQ.1) THEN
        CALL clover_pack_message_left_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%pressure,                 &
          chunk%left_snd_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_PRESSURE)+t_offset)
    
      ENDIF
      IF(fields(FIELD_VISCOSITY).EQ.1) THEN
        CALL clover_pack_message_left_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%viscosity,                &
          chunk%left_snd_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_VISCOSITY)+t_offset)
    
      ENDIF
      IF(fields(FIELD_SOUNDSPEED).EQ.1) THEN
        CALL clover_pack_message_left_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%soundspeed,               &
          chunk%left_snd_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_SOUNDSPEED)+t_offset)
    
      ENDIF
      IF(fields(FIELD_XVEL0).EQ.1) THEN
        CALL clover_pack_message_left_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%xvel0,                    &
          chunk%left_snd_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          left_right_offset(FIELD_XVEL0)+t_offset)
    
      ENDIF
      IF(fields(FIELD_XVEL1).EQ.1) THEN
        CALL clover_pack_message_left_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%xvel1,                    &
          chunk%left_snd_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          left_right_offset(FIELD_XVEL1)+t_offset)
    
      ENDIF
      IF(fields(FIELD_YVEL0).EQ.1) THEN
        CALL clover_pack_message_left_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%yvel0,                    &
          chunk%left_snd_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          left_right_offset(FIELD_YVEL0)+t_offset)
    
      ENDIF
      IF(fields(FIELD_YVEL1).EQ.1) THEN
        CALL clover_pack_message_left_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%yvel1,                    &
          chunk%left_snd_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          left_right_offset(FIELD_YVEL1)+t_offset)
    
      ENDIF
      IF(fields(FIELD_VOL_FLUX_X).EQ.1) THEN
        CALL clover_pack_message_left_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%vol_flux_x,               &
          chunk%left_snd_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, X_FACE_DATA,                           &
          left_right_offset(FIELD_VOL_FLUX_X)+t_offset)
    
      ENDIF
      IF(fields(FIELD_VOL_FLUX_Y).EQ.1) THEN
        CALL clover_pack_message_left_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%vol_flux_y,               &
          chunk%left_snd_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, Y_FACE_DATA,                           &
          left_right_offset(FIELD_VOL_FLUX_Y)+t_offset)
    
      ENDIF
      IF(fields(FIELD_MASS_FLUX_X).EQ.1) THEN
        CALL clover_pack_message_left_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%mass_flux_x,              &
          chunk%left_snd_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, X_FACE_DATA,                           &
          left_right_offset(FIELD_MASS_FLUX_X)+t_offset)
    
      ENDIF
      IF(fields(FIELD_MASS_FLUX_Y).EQ.1) THEN
        CALL clover_pack_message_left_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%mass_flux_y,              &
          chunk%left_snd_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, Y_FACE_DATA,                           &
          left_right_offset(FIELD_MASS_FLUX_Y)+t_offset)
    
      ENDIF
    ENDIF
  
  
  END SUBROUTINE clover_pack_left

  SUBROUTINE clover_send_recv_message_left(left_snd_buffer, left_rcv_buffer,      &
                                           total_size,                     &
                                           tag_send, tag_recv,                    &
                                           req_send, req_recv)
    IMPLICIT NONE

    REAL(KIND=8), POINTER    :: left_snd_buffer(:), left_rcv_buffer(:)
    integer(c_int)         :: left_task
    integer(c_int)         :: total_size, tag_send, tag_recv, err
    integer(c_int)         :: req_send, req_recv
    ! i added
    type(c_ptr) :: ptr_snd, ptr_rec
    integer :: status(MPI_STATUS_SIZE)

    left_task =chunk%chunk_neighbours(chunk_left) - 1

    ! CALL MPI_ISEND(left_snd_buffer,total_size,MPI_DOUBLE_PRECISION,left_task,tag_send &
    !   ,MPI_COMM_WORLD,req_send,err)

    ptr_snd = c_loc(left_snd_buffer)
    CALL my_MPI_Isend(ptr_snd ,total_size,MPI_DOUBLE_PRECISION,left_task,tag_send &
      ,MPI_COMM_WORLD,req_send,err)

    ! CALL my_MPI_Send(ptr_snd ,total_size,MPI_DOUBLE_PRECISION,left_task,tag_send &
    !   ,MPI_COMM_WORLD,err)

    ! CALL MPI_IRECV(left_rcv_buffer,total_size,MPI_DOUBLE_PRECISION,left_task,tag_recv &
    !   ,MPI_COMM_WORLD,req_recv,err)    
    ptr_rec = c_loc(left_rcv_buffer)

    CALL my_MPI_Irecv(ptr_rec,total_size,MPI_DOUBLE_PRECISION,left_task,tag_recv &
      ,MPI_COMM_WORLD,req_recv,err)

    ! CALL my_MPI_Recv(ptr_rec,total_size,MPI_DOUBLE_PRECISION,left_task,tag_recv &
    !   ,MPI_COMM_WORLD,status,err)

    ! call my_MPI_Sendrecv(ptr_snd, total_size, MPI_DOUBLE_PRECISION, left_task, tag_send, &
    !                         ptr_rec, total_size, MPI_DOUBLE_PRECISION, left_task, tag_recv, &
    !                         MPI_COMM_WORLD, status, err)

  END SUBROUTINE clover_send_recv_message_left

  SUBROUTINE clover_unpack_left(fields, tile, depth,                         &
                                left_rcv_buffer,                              &
                                left_right_offset)

    USE pack_kernel_module

    IMPLICIT NONE

    integer(c_int)         :: fields(:), tile, depth, t_offset
    integer(c_int)         :: left_right_offset(:)
    REAL(KIND=8)    :: left_rcv_buffer(:)

    t_offset = (chunk%tiles(tile)%t_bottom - chunk%bottom)*depth

    IF(use_fortran_kernels) THEN
      IF(fields(FIELD_DENSITY0).EQ.1) THEN
        CALL clover_unpack_message_left(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%density0,                 &
          chunk%left_rcv_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_DENSITY0)+t_offset)

      ENDIF
      IF(fields(FIELD_DENSITY1).EQ.1) THEN
        CALL clover_unpack_message_left(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%density1,                 &
          chunk%left_rcv_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_DENSITY1)+t_offset)

      ENDIF
      IF(fields(FIELD_ENERGY0).EQ.1) THEN
        CALL clover_unpack_message_left(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%energy0,                  &
          chunk%left_rcv_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_ENERGY0)+t_offset)

      ENDIF
      IF(fields(FIELD_ENERGY1).EQ.1) THEN
        CALL clover_unpack_message_left(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%energy1,                  &
          chunk%left_rcv_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_ENERGY1)+t_offset)

      ENDIF
      IF(fields(FIELD_PRESSURE).EQ.1) THEN
        CALL clover_unpack_message_left(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%pressure,                 &
          chunk%left_rcv_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_PRESSURE)+t_offset)

      ENDIF
      IF(fields(FIELD_VISCOSITY).EQ.1) THEN
        CALL clover_unpack_message_left(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%viscosity,                &
          chunk%left_rcv_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_VISCOSITY)+t_offset)

      ENDIF
      IF(fields(FIELD_SOUNDSPEED).EQ.1) THEN
        CALL clover_unpack_message_left(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%soundspeed,               &
          chunk%left_rcv_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_SOUNDSPEED)+t_offset)

      ENDIF
      IF(fields(FIELD_XVEL0).EQ.1) THEN
        CALL clover_unpack_message_left(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%xvel0,                    &
          chunk%left_rcv_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          left_right_offset(FIELD_XVEL0)+t_offset)

      ENDIF
      IF(fields(FIELD_XVEL1).EQ.1) THEN
        CALL clover_unpack_message_left(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%xvel1,                    &
          chunk%left_rcv_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          left_right_offset(FIELD_XVEL1)+t_offset)

      ENDIF
      IF(fields(FIELD_YVEL0).EQ.1) THEN
        CALL clover_unpack_message_left(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%yvel0,                    &
          chunk%left_rcv_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          left_right_offset(FIELD_YVEL0)+t_offset)

      ENDIF
      IF(fields(FIELD_YVEL1).EQ.1) THEN
        CALL clover_unpack_message_left(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%yvel1,                    &
          chunk%left_rcv_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          left_right_offset(FIELD_YVEL1)+t_offset)

      ENDIF
      IF(fields(FIELD_VOL_FLUX_X).EQ.1) THEN
        CALL clover_unpack_message_left(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%vol_flux_x,               &
          chunk%left_rcv_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, X_FACE_DATA,                           &
          left_right_offset(FIELD_VOL_FLUX_X)+t_offset)

      ENDIF
      IF(fields(FIELD_VOL_FLUX_Y).EQ.1) THEN
        CALL clover_unpack_message_left(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%vol_flux_y,               &
          chunk%left_rcv_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, Y_FACE_DATA,                           &
          left_right_offset(FIELD_VOL_FLUX_Y)+t_offset)

      ENDIF
      IF(fields(FIELD_MASS_FLUX_X).EQ.1) THEN
        CALL clover_unpack_message_left(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%mass_flux_x,              &
          chunk%left_rcv_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, X_FACE_DATA,                           &
          left_right_offset(FIELD_MASS_FLUX_X)+t_offset)

      ENDIF
      IF(fields(FIELD_MASS_FLUX_Y).EQ.1) THEN
        CALL clover_unpack_message_left(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%mass_flux_y,              &
          chunk%left_rcv_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, Y_FACE_DATA,                           &
          left_right_offset(FIELD_MASS_FLUX_Y)+t_offset)

      ENDIF

    ELSEIF(use_C_kernels) THEN
      IF(fields(FIELD_DENSITY0).EQ.1) THEN
        CALL clover_unpack_message_left_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%density0,                 &
          chunk%left_rcv_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_DENSITY0)+t_offset)
    
      ENDIF
      IF(fields(FIELD_DENSITY1).EQ.1) THEN
        CALL clover_unpack_message_left_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%density1,                 &
          chunk%left_rcv_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_DENSITY1)+t_offset)
    
      ENDIF
      IF(fields(FIELD_ENERGY0).EQ.1) THEN
        CALL clover_unpack_message_left_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%energy0,                  &
          chunk%left_rcv_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_ENERGY0)+t_offset)
    
      ENDIF
      IF(fields(FIELD_ENERGY1).EQ.1) THEN
        CALL clover_unpack_message_left_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%energy1,                  &
          chunk%left_rcv_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_ENERGY1)+t_offset)
    
      ENDIF
      IF(fields(FIELD_PRESSURE).EQ.1) THEN
        CALL clover_unpack_message_left_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%pressure,                 &
          chunk%left_rcv_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_PRESSURE)+t_offset)
    
      ENDIF
      IF(fields(FIELD_VISCOSITY).EQ.1) THEN
        CALL clover_unpack_message_left_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%viscosity,                &
          chunk%left_rcv_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_VISCOSITY)+t_offset)
    
      ENDIF
      IF(fields(FIELD_SOUNDSPEED).EQ.1) THEN
        CALL clover_unpack_message_left_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%soundspeed,               &
          chunk%left_rcv_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_SOUNDSPEED)+t_offset)
   
      ENDIF
      IF(fields(FIELD_XVEL0).EQ.1) THEN
        CALL clover_unpack_message_left_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%xvel0,                    &
          chunk%left_rcv_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          left_right_offset(FIELD_XVEL0)+t_offset)
    
      ENDIF
      IF(fields(FIELD_XVEL1).EQ.1) THEN
        CALL clover_unpack_message_left_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%xvel1,                    &
          chunk%left_rcv_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          left_right_offset(FIELD_XVEL1)+t_offset)
    
      ENDIF
      IF(fields(FIELD_YVEL0).EQ.1) THEN
        CALL clover_unpack_message_left_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%yvel0,                    &
          chunk%left_rcv_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          left_right_offset(FIELD_YVEL0)+t_offset)
    
      ENDIF
      IF(fields(FIELD_YVEL1).EQ.1) THEN
        CALL clover_unpack_message_left_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%yvel1,                    &
          chunk%left_rcv_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          left_right_offset(FIELD_YVEL1)+t_offset)
    
      ENDIF
      IF(fields(FIELD_VOL_FLUX_X).EQ.1) THEN
        CALL clover_unpack_message_left_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%vol_flux_x,               &
          chunk%left_rcv_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, X_FACE_DATA,                           &
          left_right_offset(FIELD_VOL_FLUX_X)+t_offset)
    
      ENDIF
      IF(fields(FIELD_VOL_FLUX_Y).EQ.1) THEN
        CALL clover_unpack_message_left_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%vol_flux_y,               &
          chunk%left_rcv_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, Y_FACE_DATA,                           &
          left_right_offset(FIELD_VOL_FLUX_Y)+t_offset)
    
      ENDIF
      IF(fields(FIELD_MASS_FLUX_X).EQ.1) THEN
        CALL clover_unpack_message_left_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%mass_flux_x,              &
          chunk%left_rcv_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, X_FACE_DATA,                           &
          left_right_offset(FIELD_MASS_FLUX_X)+t_offset)
    
      ENDIF
      IF(fields(FIELD_MASS_FLUX_Y).EQ.1) THEN
        CALL clover_unpack_message_left_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%mass_flux_y,              &
          chunk%left_rcv_buffer,                &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, Y_FACE_DATA,                           &
          left_right_offset(FIELD_MASS_FLUX_Y)+t_offset)
    
      ENDIF
    ENDIF

  END SUBROUTINE clover_unpack_left

  SUBROUTINE clover_pack_right(tile, fields, depth, left_right_offset)

    USE pack_kernel_module

    IMPLICIT NONE

    integer(c_int)        :: tile, fields(:), depth, tot_packr, left_right_offset(:), t_offset
  
  
    t_offset = (chunk%tiles(tile)%t_bottom - chunk%bottom)*depth
    IF(use_fortran_kernels) THEN
      IF(fields(FIELD_DENSITY0).EQ.1) THEN
        CALL clover_pack_message_right(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%density0,                 &
          chunk%right_snd_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_DENSITY0)+t_offset)

      ENDIF
      IF(fields(FIELD_DENSITY1).EQ.1) THEN
        CALL clover_pack_message_right(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%density1,                 &
          chunk%right_snd_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_DENSITY1)+t_offset)

      ENDIF
      IF(fields(FIELD_ENERGY0).EQ.1) THEN
        CALL clover_pack_message_right(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%energy0,                  &
          chunk%right_snd_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_ENERGY0)+t_offset)

      ENDIF
      IF(fields(FIELD_ENERGY1).EQ.1) THEN
        CALL clover_pack_message_right(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%energy1,                  &
          chunk%right_snd_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_ENERGY1)+t_offset)

      ENDIF
      IF(fields(FIELD_PRESSURE).EQ.1) THEN
        CALL clover_pack_message_right(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%pressure,                 &
          chunk%right_snd_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_PRESSURE)+t_offset)

      ENDIF
      IF(fields(FIELD_VISCOSITY).EQ.1) THEN
        CALL clover_pack_message_right(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%viscosity,                &
          chunk%right_snd_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_VISCOSITY)+t_offset)

      ENDIF
      IF(fields(FIELD_SOUNDSPEED).EQ.1) THEN
        CALL clover_pack_message_right(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%soundspeed,               &
          chunk%right_snd_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_SOUNDSPEED)+t_offset)

      ENDIF
      IF(fields(FIELD_XVEL0).EQ.1) THEN
        CALL clover_pack_message_right(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%xvel0,                    &
          chunk%right_snd_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          left_right_offset(FIELD_XVEL0)+t_offset)

      ENDIF
      IF(fields(FIELD_XVEL1).EQ.1) THEN
        CALL clover_pack_message_right(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%xvel1,                    &
          chunk%right_snd_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          left_right_offset(FIELD_XVEL1)+t_offset)


      ENDIF
      IF(fields(FIELD_YVEL0).EQ.1) THEN
        CALL clover_pack_message_right(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%yvel0,                    &
          chunk%right_snd_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          left_right_offset(FIELD_YVEL0)+t_offset)
      ELSE

      ENDIF
      IF(fields(FIELD_YVEL1).EQ.1) THEN
        CALL clover_pack_message_right(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%yvel1,                    &
          chunk%right_snd_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          left_right_offset(FIELD_YVEL1)+t_offset)

      ENDIF
      IF(fields(FIELD_VOL_FLUX_X).EQ.1) THEN
        CALL clover_pack_message_right(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%vol_flux_x,               &
          chunk%right_snd_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, X_FACE_DATA,                           &
          left_right_offset(FIELD_VOL_FLUX_X)+t_offset)

      ENDIF
      IF(fields(FIELD_VOL_FLUX_Y).EQ.1) THEN
        CALL clover_pack_message_right(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%vol_flux_y,               &
          chunk%right_snd_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, Y_FACE_DATA,                           &
          left_right_offset(FIELD_VOL_FLUX_Y)+t_offset)

      ENDIF
      IF(fields(FIELD_MASS_FLUX_X).EQ.1) THEN
        CALL clover_pack_message_right(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%mass_flux_x,              &
          chunk%right_snd_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, X_FACE_DATA,                           &
          left_right_offset(FIELD_MASS_FLUX_X)+t_offset)

      ENDIF
      IF(fields(FIELD_MASS_FLUX_Y).EQ.1) THEN
        CALL clover_pack_message_right(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%mass_flux_y,              &
          chunk%right_snd_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, Y_FACE_DATA,                           &
          left_right_offset(FIELD_MASS_FLUX_Y)+t_offset)

      ENDIF
    ELSEIF(use_C_kernels) THEN
      IF(fields(FIELD_DENSITY0).EQ.1) THEN
        CALL clover_pack_message_right_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%density0,                 &
          chunk%right_snd_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_DENSITY0)+t_offset)
   
      ENDIF
      IF(fields(FIELD_DENSITY1).EQ.1) THEN
        CALL clover_pack_message_right_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%density1,                 &
          chunk%right_snd_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_DENSITY1)+t_offset)

      ENDIF
      IF(fields(FIELD_ENERGY0).EQ.1) THEN
        CALL clover_pack_message_right_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%energy0,                  &
          chunk%right_snd_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_ENERGY0)+t_offset)

      ENDIF
      IF(fields(FIELD_ENERGY1).EQ.1) THEN
        CALL clover_pack_message_right_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%energy1,                  &
          chunk%right_snd_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_ENERGY1)+t_offset)

      ENDIF
      IF(fields(FIELD_PRESSURE).EQ.1) THEN
        CALL clover_pack_message_right_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%pressure,                 &
          chunk%right_snd_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_PRESSURE)+t_offset)

      ENDIF
      IF(fields(FIELD_VISCOSITY).EQ.1) THEN
        CALL clover_pack_message_right_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%viscosity,                &
          chunk%right_snd_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_VISCOSITY)+t_offset)

      ENDIF
      IF(fields(FIELD_SOUNDSPEED).EQ.1) THEN
        CALL clover_pack_message_right_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%soundspeed,               &
          chunk%right_snd_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_SOUNDSPEED)+t_offset)

      ENDIF
      IF(fields(FIELD_XVEL0).EQ.1) THEN
        CALL clover_pack_message_right_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%xvel0,                    &
          chunk%right_snd_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          left_right_offset(FIELD_XVEL0)+t_offset)

      ENDIF
      IF(fields(FIELD_XVEL1).EQ.1) THEN
        CALL clover_pack_message_right_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%xvel1,                    &
          chunk%right_snd_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          left_right_offset(FIELD_XVEL1)+t_offset)
 

      ENDIF
      IF(fields(FIELD_YVEL0).EQ.1) THEN
        CALL clover_pack_message_right_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%yvel0,                    &
          chunk%right_snd_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          left_right_offset(FIELD_YVEL0)+t_offset)
      ELSE

      ENDIF
      IF(fields(FIELD_YVEL1).EQ.1) THEN
        CALL clover_pack_message_right_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%yvel1,                    &
          chunk%right_snd_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          left_right_offset(FIELD_YVEL1)+t_offset)

      ENDIF
      IF(fields(FIELD_VOL_FLUX_X).EQ.1) THEN
        CALL clover_pack_message_right_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%vol_flux_x,               &
          chunk%right_snd_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, X_FACE_DATA,                           &
          left_right_offset(FIELD_VOL_FLUX_X)+t_offset)

      ENDIF
      IF(fields(FIELD_VOL_FLUX_Y).EQ.1) THEN
        CALL clover_pack_message_right_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%vol_flux_y,               &
          chunk%right_snd_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, Y_FACE_DATA,                           &
          left_right_offset(FIELD_VOL_FLUX_Y)+t_offset)

      ENDIF
      IF(fields(FIELD_MASS_FLUX_X).EQ.1) THEN
        CALL clover_pack_message_right_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%mass_flux_x,              &
          chunk%right_snd_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, X_FACE_DATA,                           &
          left_right_offset(FIELD_MASS_FLUX_X)+t_offset)

      ENDIF
      IF(fields(FIELD_MASS_FLUX_Y).EQ.1) THEN
        CALL clover_pack_message_right_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%mass_flux_y,              &
          chunk%right_snd_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, Y_FACE_DATA,                           &
          left_right_offset(FIELD_MASS_FLUX_Y)+t_offset)

      ENDIF
    ENDIF
  
  END SUBROUTINE clover_pack_right

  SUBROUTINE clover_send_recv_message_right(right_snd_buffer, right_rcv_buffer,   &
                                            total_size,                    &
                                            tag_send, tag_recv,                   &
                                            req_send, req_recv)

    IMPLICIT NONE

    REAL(KIND=8), POINTER :: right_snd_buffer(:), right_rcv_buffer(:)
    integer(c_int)      :: right_task
    integer(c_int)      :: total_size, tag_send, tag_recv, err
    integer(c_int)      :: req_send, req_recv
    ! i added
    type(c_ptr) :: ptr_snd, ptr_rec
    integer :: status(MPI_STATUS_SIZE)

    right_task=chunk%chunk_neighbours(chunk_right) - 1

    ! CALL MPI_ISEND(right_snd_buffer,total_size,MPI_DOUBLE_PRECISION,right_task,tag_send, &
    !   MPI_COMM_WORLD,req_send,err)

    ptr_snd = c_loc(right_snd_buffer)
    ! i changed the dest to 0
    ! no more seg faults
    CALL my_MPI_Isend(ptr_snd,total_size,MPI_DOUBLE_PRECISION,0,tag_send, &
      MPI_COMM_WORLD,req_send,err)

    ! CALL my_MPI_Send(ptr_snd,total_size,MPI_DOUBLE_PRECISION,right_task,tag_send, &
    !   MPI_COMM_WORLD,err)

    ! CALL MPI_IRECV(right_rcv_buffer,total_size,MPI_DOUBLE_PRECISION,right_task,tag_recv, &
    !   MPI_COMM_WORLD,req_recv,err)

    ptr_rec = c_loc(right_rcv_buffer)
    CALL my_MPI_Irecv(ptr_rec,total_size,MPI_DOUBLE_PRECISION,0,tag_recv, &
      MPI_COMM_WORLD,req_recv,err)

    ! CALL my_MPI_Recv(ptr_rec,total_size,MPI_DOUBLE_PRECISION,right_task,tag_recv, &
    !   MPI_COMM_WORLD,status,err)

    ! call my_MPI_Sendrecv(ptr_snd, total_size, MPI_DOUBLE_PRECISION, right_task, tag_send, &
    !                     ptr_rec, total_size, MPI_DOUBLE_PRECISION, right_task, tag_recv, &
    !                     MPI_COMM_WORLD, status, err)

  END SUBROUTINE clover_send_recv_message_right

  SUBROUTINE clover_unpack_right(fields, tile, depth,                          &
                                 right_rcv_buffer,                              &
                                 left_right_offset)

    USE pack_kernel_module

    IMPLICIT NONE

    INTEGER(c_int)        :: fields(:), tile, total_in_right_buff, depth, left_right_offset(:), t_offset
    REAL(KIND=8)    :: right_rcv_buffer(:)
  
    t_offset = (chunk%tiles(tile)%t_bottom - chunk%bottom)*depth
    IF(use_fortran_kernels) THEN
      IF(fields(FIELD_DENSITY0).EQ.1) THEN
        CALL clover_unpack_message_right(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%density0,                 &
          chunk%right_rcv_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_DENSITY0)+t_offset)

      ENDIF

      IF(fields(FIELD_DENSITY1).EQ.1) THEN
        CALL clover_unpack_message_right(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%density1,                 &
          chunk%right_rcv_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_DENSITY1)+t_offset)

      ENDIF
      IF(fields(FIELD_ENERGY0).EQ.1) THEN
        CALL clover_unpack_message_right(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%energy0,                  &
          chunk%right_rcv_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_ENERGY0)+t_offset)

      ENDIF
      IF(fields(FIELD_ENERGY1).EQ.1) THEN
        CALL clover_unpack_message_right(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%energy1,                  &
          chunk%right_rcv_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_ENERGY1)+t_offset)

      ENDIF
      IF(fields(FIELD_PRESSURE).EQ.1) THEN
        CALL clover_unpack_message_right(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%pressure,                 &
          chunk%right_rcv_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_PRESSURE)+t_offset)

      ENDIF
      IF(fields(FIELD_VISCOSITY).EQ.1) THEN
        CALL clover_unpack_message_right(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%viscosity,                &
          chunk%right_rcv_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_VISCOSITY)+t_offset)

      ENDIF
      IF(fields(FIELD_SOUNDSPEED).EQ.1) THEN
        CALL clover_unpack_message_right(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%soundspeed,               &
          chunk%right_rcv_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_SOUNDSPEED)+t_offset)

      ENDIF
      IF(fields(FIELD_XVEL0).EQ.1) THEN
        CALL clover_unpack_message_right(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%xvel0,                    &
          chunk%right_rcv_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          left_right_offset(FIELD_XVEL0)+t_offset)

      ENDIF
      IF(fields(FIELD_XVEL1).EQ.1) THEN
        CALL clover_unpack_message_right(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%xvel1,                    &
          chunk%right_rcv_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          left_right_offset(FIELD_XVEL1)+t_offset)

      ENDIF
      IF(fields(FIELD_YVEL0).EQ.1) THEN
        CALL clover_unpack_message_right(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%yvel0,                    &
          chunk%right_rcv_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          left_right_offset(FIELD_YVEL0)+t_offset)

      ENDIF
      IF(fields(FIELD_YVEL1).EQ.1) THEN
        CALL clover_unpack_message_right(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%yvel1,                    &
          chunk%right_rcv_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          left_right_offset(FIELD_YVEL1)+t_offset)

      ENDIF
      IF(fields(FIELD_VOL_FLUX_X).EQ.1) THEN
        CALL clover_unpack_message_right(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%vol_flux_x,               &
          chunk%right_rcv_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, X_FACE_DATA,                           &
          left_right_offset(FIELD_VOL_FLUX_X)+t_offset)

      ENDIF
      IF(fields(FIELD_VOL_FLUX_Y).EQ.1) THEN
        CALL clover_unpack_message_right(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%vol_flux_y,               &
          chunk%right_rcv_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, Y_FACE_DATA,                           &
          left_right_offset(FIELD_VOL_FLUX_Y)+t_offset)

      ENDIF
      IF(fields(FIELD_MASS_FLUX_X).EQ.1) THEN
        CALL clover_unpack_message_right(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%mass_flux_x,              &
          chunk%right_rcv_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, X_FACE_DATA,                           &
          left_right_offset(FIELD_MASS_FLUX_X)+t_offset)

      ENDIF
      IF(fields(FIELD_MASS_FLUX_Y).EQ.1) THEN
        CALL clover_unpack_message_right(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%mass_flux_y,              &
          chunk%right_rcv_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, Y_FACE_DATA,                           &
          left_right_offset(FIELD_MASS_FLUX_Y)+t_offset)

      ENDIF
    ELSEIF(use_C_kernels) THEN
      IF(fields(FIELD_DENSITY0).EQ.1) THEN
        CALL clover_unpack_message_right_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%density0,                 &
          chunk%right_rcv_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_DENSITY0)+t_offset)

      ENDIF

      IF(fields(FIELD_DENSITY1).EQ.1) THEN
        CALL clover_unpack_message_right_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%density1,                 &
          chunk%right_rcv_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_DENSITY1)+t_offset)

      ENDIF
      IF(fields(FIELD_ENERGY0).EQ.1) THEN
        CALL clover_unpack_message_right_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%energy0,                  &
          chunk%right_rcv_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_ENERGY0)+t_offset)

      ENDIF
      IF(fields(FIELD_ENERGY1).EQ.1) THEN
        CALL clover_unpack_message_right_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%energy1,                  &
          chunk%right_rcv_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_ENERGY1)+t_offset)

      ENDIF
      IF(fields(FIELD_PRESSURE).EQ.1) THEN
        CALL clover_unpack_message_right_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%pressure,                 &
          chunk%right_rcv_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_PRESSURE)+t_offset)

      ENDIF
      IF(fields(FIELD_VISCOSITY).EQ.1) THEN
        CALL clover_unpack_message_right_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%viscosity,                &
          chunk%right_rcv_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_VISCOSITY)+t_offset)

      ENDIF
      IF(fields(FIELD_SOUNDSPEED).EQ.1) THEN
        CALL clover_unpack_message_right_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%soundspeed,               &
          chunk%right_rcv_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          left_right_offset(FIELD_SOUNDSPEED)+t_offset)

      ENDIF
      IF(fields(FIELD_XVEL0).EQ.1) THEN
        CALL clover_unpack_message_right_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%xvel0,                    &
          chunk%right_rcv_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          left_right_offset(FIELD_XVEL0)+t_offset)

      ENDIF
      IF(fields(FIELD_XVEL1).EQ.1) THEN
        CALL clover_unpack_message_right_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%xvel1,                    &
          chunk%right_rcv_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          left_right_offset(FIELD_XVEL1)+t_offset)

      ENDIF
      IF(fields(FIELD_YVEL0).EQ.1) THEN
        CALL clover_unpack_message_right_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%yvel0,                    &
          chunk%right_rcv_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          left_right_offset(FIELD_YVEL0)+t_offset)

      ENDIF
      IF(fields(FIELD_YVEL1).EQ.1) THEN
        CALL clover_unpack_message_right_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%yvel1,                    &
          chunk%right_rcv_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          left_right_offset(FIELD_YVEL1)+t_offset)

      ENDIF
      IF(fields(FIELD_VOL_FLUX_X).EQ.1) THEN
        CALL clover_unpack_message_right_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%vol_flux_x,               &
          chunk%right_rcv_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, X_FACE_DATA,                           &
          left_right_offset(FIELD_VOL_FLUX_X)+t_offset)

      ENDIF
      IF(fields(FIELD_VOL_FLUX_Y).EQ.1) THEN
        CALL clover_unpack_message_right_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%vol_flux_y,               &
          chunk%right_rcv_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, Y_FACE_DATA,                           &
          left_right_offset(FIELD_VOL_FLUX_Y)+t_offset)

      ENDIF
      IF(fields(FIELD_MASS_FLUX_X).EQ.1) THEN
        CALL clover_unpack_message_right_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%mass_flux_x,              &
          chunk%right_rcv_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, X_FACE_DATA,                           &
          left_right_offset(FIELD_MASS_FLUX_X)+t_offset)

      ENDIF
      IF(fields(FIELD_MASS_FLUX_Y).EQ.1) THEN
        CALL clover_unpack_message_right_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%mass_flux_y,              &
          chunk%right_rcv_buffer,               &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, Y_FACE_DATA,                           &
          left_right_offset(FIELD_MASS_FLUX_Y)+t_offset)

      ENDIF
    ENDIF

  END SUBROUTINE clover_unpack_right

  SUBROUTINE clover_pack_top(tile, fields, depth, bottom_top_offset)

    USE pack_kernel_module

    IMPLICIT NONE

    INTEGER(c_int)        :: tile, fields(:), depth, bottom_top_offset(:), t_offset
  
    t_offset = (chunk%tiles(tile)%t_left - chunk%left)*depth
    IF(use_fortran_kernels) THEN
      IF(fields(FIELD_DENSITY0).EQ.1) THEN
        CALL clover_pack_message_top(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%density0,                 &
          chunk%top_snd_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_DENSITY0)+t_offset)

      ENDIF
      IF(fields(FIELD_DENSITY1).EQ.1) THEN
        CALL clover_pack_message_top(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%density1,                 &
          chunk%top_snd_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_DENSITY1)+t_offset)

      ENDIF
      IF(fields(FIELD_ENERGY0).EQ.1) THEN
        CALL clover_pack_message_top(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%energy0,                  &
          chunk%top_snd_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_ENERGY0)+t_offset)

      ENDIF
      IF(fields(FIELD_ENERGY1).EQ.1) THEN
        CALL clover_pack_message_top(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%energy1,                  &
          chunk%top_snd_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_ENERGY1)+t_offset)

      ENDIF
      IF(fields(FIELD_PRESSURE).EQ.1) THEN
        CALL clover_pack_message_top(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%pressure,                 &
          chunk%top_snd_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_PRESSURE)+t_offset)

      ENDIF
      IF(fields(FIELD_VISCOSITY).EQ.1) THEN
        CALL clover_pack_message_top(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%viscosity,                &
          chunk%top_snd_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_VISCOSITY)+t_offset)

      ENDIF
      IF(fields(FIELD_SOUNDSPEED).EQ.1) THEN
        CALL clover_pack_message_top(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%soundspeed,               &
          chunk%top_snd_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_SOUNDSPEED)+t_offset)

      ENDIF
      IF(fields(FIELD_XVEL0).EQ.1) THEN
        CALL clover_pack_message_top(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%xvel0,                    &
          chunk%top_snd_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          bottom_top_offset(FIELD_XVEL0)+t_offset)

      ENDIF
      IF(fields(FIELD_XVEL1).EQ.1) THEN
        CALL clover_pack_message_top(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%xvel1,                    &
          chunk%top_snd_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          bottom_top_offset(FIELD_XVEL1)+t_offset)

      ENDIF
      IF(fields(FIELD_YVEL0).EQ.1) THEN
        CALL clover_pack_message_top(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%yvel0,                    &
          chunk%top_snd_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          bottom_top_offset(FIELD_YVEL0)+t_offset)

      ENDIF
      IF(fields(FIELD_YVEL1).EQ.1) THEN
        CALL clover_pack_message_top(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%yvel1,                    &
          chunk%top_snd_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          bottom_top_offset(FIELD_YVEL1)+t_offset)

      ENDIF
      IF(fields(FIELD_VOL_FLUX_X).EQ.1) THEN
        CALL clover_pack_message_top(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%vol_flux_x,               &
          chunk%top_snd_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, X_FACE_DATA,                           &
          bottom_top_offset(FIELD_VOL_FLUX_X)+t_offset)

      ENDIF
      IF(fields(FIELD_VOL_FLUX_Y).EQ.1) THEN
        CALL clover_pack_message_top(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%vol_flux_y,               &
          chunk%top_snd_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, Y_FACE_DATA,                           &
          bottom_top_offset(FIELD_VOL_FLUX_Y)+t_offset)

      ENDIF
      IF(fields(FIELD_MASS_FLUX_X).EQ.1) THEN
        CALL clover_pack_message_top(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%mass_flux_x,              &
          chunk%top_snd_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, X_FACE_DATA,                           &
          bottom_top_offset(FIELD_MASS_FLUX_X)+t_offset)

      ENDIF
      IF(fields(FIELD_MASS_FLUX_Y).EQ.1) THEN
        CALL clover_pack_message_top(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%mass_flux_y,              &
          chunk%top_snd_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, Y_FACE_DATA,                           &
          bottom_top_offset(FIELD_MASS_FLUX_Y)+t_offset)

      ENDIF

    ELSEIF(use_C_kernels) THEN
      IF(fields(FIELD_DENSITY0).EQ.1) THEN
        CALL clover_pack_message_top_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%density0,                 &
          chunk%top_snd_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_DENSITY0)+t_offset)

      ENDIF
      IF(fields(FIELD_DENSITY1).EQ.1) THEN
        CALL clover_pack_message_top_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%density1,                 &
          chunk%top_snd_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_DENSITY1)+t_offset)

      ENDIF
      IF(fields(FIELD_ENERGY0).EQ.1) THEN
        CALL clover_pack_message_top_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%energy0,                  &
          chunk%top_snd_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_ENERGY0)+t_offset)

      ENDIF
      IF(fields(FIELD_ENERGY1).EQ.1) THEN
        CALL clover_pack_message_top_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%energy1,                  &
          chunk%top_snd_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_ENERGY1)+t_offset)

      ENDIF
      IF(fields(FIELD_PRESSURE).EQ.1) THEN
        CALL clover_pack_message_top_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%pressure,                 &
          chunk%top_snd_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_PRESSURE)+t_offset)

      ENDIF
      IF(fields(FIELD_VISCOSITY).EQ.1) THEN
        CALL clover_pack_message_top_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%viscosity,                &
          chunk%top_snd_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_VISCOSITY)+t_offset)

      ENDIF
      IF(fields(FIELD_SOUNDSPEED).EQ.1) THEN
        CALL clover_pack_message_top_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%soundspeed,               &
          chunk%top_snd_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_SOUNDSPEED)+t_offset)

      ENDIF
      IF(fields(FIELD_XVEL0).EQ.1) THEN
        CALL clover_pack_message_top_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%xvel0,                    &
          chunk%top_snd_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          bottom_top_offset(FIELD_XVEL0)+t_offset)

      ENDIF
      IF(fields(FIELD_XVEL1).EQ.1) THEN
        CALL clover_pack_message_top_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%xvel1,                    &
          chunk%top_snd_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          bottom_top_offset(FIELD_XVEL1)+t_offset)

      ENDIF
      IF(fields(FIELD_YVEL0).EQ.1) THEN
        CALL clover_pack_message_top_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%yvel0,                    &
          chunk%top_snd_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          bottom_top_offset(FIELD_YVEL0)+t_offset)

      ENDIF
      IF(fields(FIELD_YVEL1).EQ.1) THEN
        CALL clover_pack_message_top_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%yvel1,                    &
          chunk%top_snd_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          bottom_top_offset(FIELD_YVEL1)+t_offset)

      ENDIF
      IF(fields(FIELD_VOL_FLUX_X).EQ.1) THEN
        CALL clover_pack_message_top_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%vol_flux_x,               &
          chunk%top_snd_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, X_FACE_DATA,                           &
          bottom_top_offset(FIELD_VOL_FLUX_X)+t_offset)

      ENDIF
      IF(fields(FIELD_VOL_FLUX_Y).EQ.1) THEN
        CALL clover_pack_message_top_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%vol_flux_y,               &
          chunk%top_snd_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, Y_FACE_DATA,                           &
          bottom_top_offset(FIELD_VOL_FLUX_Y)+t_offset)

      ENDIF
      IF(fields(FIELD_MASS_FLUX_X).EQ.1) THEN
        CALL clover_pack_message_top_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%mass_flux_x,              &
          chunk%top_snd_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, X_FACE_DATA,                           &
          bottom_top_offset(FIELD_MASS_FLUX_X)+t_offset)

      ENDIF
      IF(fields(FIELD_MASS_FLUX_Y).EQ.1) THEN
        CALL clover_pack_message_top_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%mass_flux_y,              &
          chunk%top_snd_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, Y_FACE_DATA,                           &
          bottom_top_offset(FIELD_MASS_FLUX_Y)+t_offset)

      ENDIF
    ENDIF
  END SUBROUTINE clover_pack_top

  SUBROUTINE clover_send_recv_message_top(top_snd_buffer, top_rcv_buffer,     &
                                          total_size,                  &
                                          tag_send, tag_recv,                 &
                                          req_send, req_recv)

    IMPLICIT NONE

    REAL(KIND=8), POINTER :: top_snd_buffer(:), top_rcv_buffer(:)
    integer(c_int)      :: top_task
    integer(c_int)      :: total_size, tag_send, tag_recv, err
    integer(c_int)      :: req_send, req_recv
    
    ! i added
    type(c_ptr) :: ptr_snd, ptr_rec
    integer :: status(MPI_STATUS_SIZE)

    top_task=chunk%chunk_neighbours(chunk_top) - 1

    ! CALL MPI_ISEND(top_snd_buffer,total_size,MPI_DOUBLE_PRECISION,top_task,tag_send, &
    !   MPI_COMM_WORLD,req_send,err)

    ptr_snd = c_loc(top_snd_buffer)
    CALL my_MPI_Isend(ptr_snd ,total_size,MPI_DOUBLE_PRECISION,top_task,tag_send, &
      MPI_COMM_WORLD,req_send,err)

    ! CALL my_MPI_Send(ptr_snd,total_size,MPI_DOUBLE_PRECISION,top_task,tag_send, &
    !   MPI_COMM_WORLD,err)

    ! CALL MPI_IRECV(top_rcv_buffer,total_size,MPI_DOUBLE_PRECISION,top_task,tag_recv, &
    !   MPI_COMM_WORLD,req_recv,err)

    ptr_rec = c_loc(top_rcv_buffer)
    CALL my_MPI_Irecv(ptr_rec,total_size,MPI_DOUBLE_PRECISION,top_task,tag_recv, &
      MPI_COMM_WORLD,req_recv,err)

    ! CALL my_MPI_Recv(ptr_rec,total_size,MPI_DOUBLE_PRECISION,top_task,tag_recv, &
    !   MPI_COMM_WORLD,status,err)

    ! call my_MPI_Sendrecv(ptr_snd, total_size, MPI_DOUBLE_PRECISION, top_task, tag_send, &
    !                     ptr_rec, total_size, MPI_DOUBLE_PRECISION, top_task, tag_recv, &
    !                     MPI_COMM_WORLD, status, err)    

  END SUBROUTINE clover_send_recv_message_top

  SUBROUTINE clover_unpack_top(fields, tile, depth,                        &
                               top_rcv_buffer,                              &
                               bottom_top_offset)

    USE pack_kernel_module

    IMPLICIT NONE

    integer(c_int)         :: fields(:), tile, total_in_top_buff, depth, bottom_top_offset(:), t_offset
    REAL(KIND=8)    :: top_rcv_buffer(:)
  
    t_offset = (chunk%tiles(tile)%t_left - chunk%left)*depth
    IF(use_fortran_kernels) THEN
      IF(fields(FIELD_DENSITY0).EQ.1) THEN
        CALL clover_unpack_message_top(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%density0,                 &
          chunk%top_rcv_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_DENSITY0)+t_offset)

      ENDIF
      IF(fields(FIELD_DENSITY1).EQ.1) THEN
        CALL clover_unpack_message_top(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%density1,                 &
          chunk%top_rcv_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_DENSITY1)+t_offset)

      ENDIF
      IF(fields(FIELD_ENERGY0).EQ.1) THEN
        CALL clover_unpack_message_top(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%energy0,                  &
          chunk%top_rcv_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_ENERGY0)+t_offset)

      ENDIF
      IF(fields(FIELD_ENERGY1).EQ.1) THEN
        CALL clover_unpack_message_top(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%energy1,                  &
          chunk%top_rcv_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_ENERGY1)+t_offset)

      ENDIF
      IF(fields(FIELD_PRESSURE).EQ.1) THEN
        CALL clover_unpack_message_top(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%pressure,                 &
          chunk%top_rcv_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_PRESSURE)+t_offset)

      ENDIF
      IF(fields(FIELD_VISCOSITY).EQ.1) THEN
        CALL clover_unpack_message_top(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%viscosity,                &
          chunk%top_rcv_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_VISCOSITY)+t_offset)

      ENDIF
      IF(fields(FIELD_SOUNDSPEED).EQ.1) THEN
        CALL clover_unpack_message_top(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%soundspeed,               &
          chunk%top_rcv_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_SOUNDSPEED)+t_offset)

      ENDIF
      IF(fields(FIELD_XVEL0).EQ.1) THEN
        CALL clover_unpack_message_top(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%xvel0,                    &
          chunk%top_rcv_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          bottom_top_offset(FIELD_XVEL0)+t_offset)

      ENDIF
      IF(fields(FIELD_XVEL1).EQ.1) THEN
        CALL clover_unpack_message_top(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%xvel1,                    &
          chunk%top_rcv_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          bottom_top_offset(FIELD_XVEL1)+t_offset)

      ENDIF
      IF(fields(FIELD_YVEL0).EQ.1) THEN
        CALL clover_unpack_message_top(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%yvel0,                    &
          chunk%top_rcv_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          bottom_top_offset(FIELD_YVEL0)+t_offset)

      ENDIF
      IF(fields(FIELD_YVEL1).EQ.1) THEN
        CALL clover_unpack_message_top(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%yvel1,                    &
          chunk%top_rcv_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          bottom_top_offset(FIELD_YVEL1)+t_offset)

      ENDIF
      IF(fields(FIELD_VOL_FLUX_X).EQ.1) THEN
        CALL clover_unpack_message_top(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%vol_flux_x,               &
          chunk%top_rcv_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, X_FACE_DATA,                           &
          bottom_top_offset(FIELD_VOL_FLUX_X)+t_offset)

      ENDIF
      IF(fields(FIELD_VOL_FLUX_Y).EQ.1) THEN
        CALL clover_unpack_message_top(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%vol_flux_y,               &
          chunk%top_rcv_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, Y_FACE_DATA,                           &
          bottom_top_offset(FIELD_VOL_FLUX_Y)+t_offset)

      ENDIF
      IF(fields(FIELD_MASS_FLUX_X).EQ.1) THEN
        CALL clover_unpack_message_top(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%mass_flux_x,              &
          chunk%top_rcv_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, X_FACE_DATA,                           &
          bottom_top_offset(FIELD_MASS_FLUX_X)+t_offset)

      ENDIF
      IF(fields(FIELD_MASS_FLUX_Y).EQ.1) THEN
        CALL clover_unpack_message_top(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%mass_flux_y,              &
          chunk%top_rcv_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, Y_FACE_DATA,                           &
          bottom_top_offset(FIELD_MASS_FLUX_Y)+t_offset)

      ENDIF
    ELSEIF(use_C_kernels) THEN
      IF(fields(FIELD_DENSITY0).EQ.1) THEN
        CALL clover_unpack_message_top_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%density0,                 &
          chunk%top_rcv_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_DENSITY0)+t_offset)

      ENDIF
      IF(fields(FIELD_DENSITY1).EQ.1) THEN
        CALL clover_unpack_message_top_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%density1,                 &
          chunk%top_rcv_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_DENSITY1)+t_offset)

      ENDIF
      IF(fields(FIELD_ENERGY0).EQ.1) THEN
        CALL clover_unpack_message_top_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%energy0,                  &
          chunk%top_rcv_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_ENERGY0)+t_offset)

      ENDIF
      IF(fields(FIELD_ENERGY1).EQ.1) THEN
        CALL clover_unpack_message_top_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%energy1,                  &
          chunk%top_rcv_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_ENERGY1)+t_offset)

      ENDIF
      IF(fields(FIELD_PRESSURE).EQ.1) THEN
        CALL clover_unpack_message_top_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%pressure,                 &
          chunk%top_rcv_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_PRESSURE)+t_offset)

      ENDIF
      IF(fields(FIELD_VISCOSITY).EQ.1) THEN
        CALL clover_unpack_message_top_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%viscosity,                &
          chunk%top_rcv_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_VISCOSITY)+t_offset)

      ENDIF
      IF(fields(FIELD_SOUNDSPEED).EQ.1) THEN
        CALL clover_unpack_message_top_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%soundspeed,               &
          chunk%top_rcv_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_SOUNDSPEED)+t_offset)

      ENDIF
      IF(fields(FIELD_XVEL0).EQ.1) THEN
        CALL clover_unpack_message_top_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%xvel0,                    &
          chunk%top_rcv_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          bottom_top_offset(FIELD_XVEL0)+t_offset)

      ENDIF
      IF(fields(FIELD_XVEL1).EQ.1) THEN
        CALL clover_unpack_message_top_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%xvel1,                    &
          chunk%top_rcv_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          bottom_top_offset(FIELD_XVEL1)+t_offset)

      ENDIF
      IF(fields(FIELD_YVEL0).EQ.1) THEN
        CALL clover_unpack_message_top_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%yvel0,                    &
          chunk%top_rcv_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          bottom_top_offset(FIELD_YVEL0)+t_offset)

      ENDIF
      IF(fields(FIELD_YVEL1).EQ.1) THEN
        CALL clover_unpack_message_top_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%yvel1,                    &
          chunk%top_rcv_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          bottom_top_offset(FIELD_YVEL1)+t_offset)

      ENDIF
      IF(fields(FIELD_VOL_FLUX_X).EQ.1) THEN
        CALL clover_unpack_message_top_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%vol_flux_x,               &
          chunk%top_rcv_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, X_FACE_DATA,                           &
          bottom_top_offset(FIELD_VOL_FLUX_X)+t_offset)

      ENDIF
      IF(fields(FIELD_VOL_FLUX_Y).EQ.1) THEN
        CALL clover_unpack_message_top_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%vol_flux_y,               &
          chunk%top_rcv_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, Y_FACE_DATA,                           &
          bottom_top_offset(FIELD_VOL_FLUX_Y)+t_offset)

      ENDIF
      IF(fields(FIELD_MASS_FLUX_X).EQ.1) THEN
        CALL clover_unpack_message_top_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%mass_flux_x,              &
          chunk%top_rcv_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, X_FACE_DATA,                           &
          bottom_top_offset(FIELD_MASS_FLUX_X)+t_offset)

      ENDIF
      IF(fields(FIELD_MASS_FLUX_Y).EQ.1) THEN
        CALL clover_unpack_message_top_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%mass_flux_y,              &
          chunk%top_rcv_buffer,                 &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, Y_FACE_DATA,                           &
          bottom_top_offset(FIELD_MASS_FLUX_Y)+t_offset)

      ENDIF
    ENDIF


  END SUBROUTINE clover_unpack_top

  SUBROUTINE clover_pack_bottom(tile, fields, depth, bottom_top_offset)

    USE pack_kernel_module

    IMPLICIT NONE

    integer(c_int)        :: tile, fields(:), depth, tot_packb, bottom_top_offset(:), t_offset
  
    t_offset = (chunk%tiles(tile)%t_left - chunk%left)*depth
    IF(use_fortran_kernels) THEN
      IF(fields(FIELD_DENSITY0).EQ.1) THEN
        CALL clover_pack_message_bottom(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%density0,                 &
          chunk%bottom_snd_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_DENSITY0)+t_offset)
      ELSE

      ENDIF
      IF(fields(FIELD_DENSITY1).EQ.1) THEN
        CALL clover_pack_message_bottom(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%density1,                 &
          chunk%bottom_snd_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_DENSITY1)+t_offset)

      ENDIF
      IF(fields(FIELD_ENERGY0).EQ.1) THEN
        CALL clover_pack_message_bottom(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%energy0,                  &
          chunk%bottom_snd_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_ENERGY0)+t_offset)

      ENDIF
      IF(fields(FIELD_ENERGY1).EQ.1) THEN
        CALL clover_pack_message_bottom(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%energy1,                  &
          chunk%bottom_snd_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_ENERGY1)+t_offset)

      ENDIF
      IF(fields(FIELD_PRESSURE).EQ.1) THEN
        CALL clover_pack_message_bottom(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%pressure,                 &
          chunk%bottom_snd_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_PRESSURE)+t_offset)

      ENDIF
      IF(fields(FIELD_VISCOSITY).EQ.1) THEN
        CALL clover_pack_message_bottom(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%viscosity,                &
          chunk%bottom_snd_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_VISCOSITY)+t_offset)

      ENDIF
      IF(fields(FIELD_SOUNDSPEED).EQ.1) THEN
        CALL clover_pack_message_bottom(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%soundspeed,               &
          chunk%bottom_snd_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_SOUNDSPEED)+t_offset)

      ENDIF
      IF(fields(FIELD_XVEL0).EQ.1) THEN
        CALL clover_pack_message_bottom(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%xvel0,                    &
          chunk%bottom_snd_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          bottom_top_offset(FIELD_XVEL0)+t_offset)

      ENDIF
      IF(fields(FIELD_XVEL1).EQ.1) THEN
        CALL clover_pack_message_bottom(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%xvel1,                    &
          chunk%bottom_snd_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          bottom_top_offset(FIELD_XVEL1)+t_offset)

      ENDIF
      IF(fields(FIELD_YVEL0).EQ.1) THEN
        CALL clover_pack_message_bottom(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%yvel0,                    &
          chunk%bottom_snd_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          bottom_top_offset(FIELD_YVEL0)+t_offset)

      ENDIF
      IF(fields(FIELD_YVEL1).EQ.1) THEN
        CALL clover_pack_message_bottom(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%yvel1,                    &
          chunk%bottom_snd_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          bottom_top_offset(FIELD_YVEL1)+t_offset)

      ENDIF
      IF(fields(FIELD_VOL_FLUX_X).EQ.1) THEN
        CALL clover_pack_message_bottom(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%vol_flux_x,               &
          chunk%bottom_snd_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, X_FACE_DATA,                           &
          bottom_top_offset(FIELD_VOL_FLUX_X)+t_offset)

      ENDIF
      IF(fields(FIELD_VOL_FLUX_Y).EQ.1) THEN
        CALL clover_pack_message_bottom(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%vol_flux_y,               &
          chunk%bottom_snd_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, Y_FACE_DATA,                           &
          bottom_top_offset(FIELD_VOL_FLUX_Y)+t_offset)

      ENDIF
      IF(fields(FIELD_MASS_FLUX_X).EQ.1) THEN
        CALL clover_pack_message_bottom(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%mass_flux_x,              &
          chunk%bottom_snd_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, X_FACE_DATA,                           &
          bottom_top_offset(FIELD_MASS_FLUX_X)+t_offset)

      ENDIF
      IF(fields(FIELD_MASS_FLUX_Y).EQ.1) THEN
        CALL clover_pack_message_bottom(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%mass_flux_y,              &
          chunk%bottom_snd_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, Y_FACE_DATA,                           &
          bottom_top_offset(FIELD_MASS_FLUX_Y)+t_offset)

      ENDIF

    ELSEIF(use_C_kernels) THEN
      IF(fields(FIELD_DENSITY0).EQ.1) THEN
        CALL clover_pack_message_bottom_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%density0,                 &
          chunk%bottom_snd_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_DENSITY0)+t_offset)
      ELSE

      ENDIF
      IF(fields(FIELD_DENSITY1).EQ.1) THEN
        CALL clover_pack_message_bottom_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%density1,                 &
          chunk%bottom_snd_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_DENSITY1)+t_offset)

      ENDIF
      IF(fields(FIELD_ENERGY0).EQ.1) THEN
        CALL clover_pack_message_bottom_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%energy0,                  &
          chunk%bottom_snd_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_ENERGY0)+t_offset)

      ENDIF
      IF(fields(FIELD_ENERGY1).EQ.1) THEN
        CALL clover_pack_message_bottom_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%energy1,                  &
          chunk%bottom_snd_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_ENERGY1)+t_offset)

      ENDIF
      IF(fields(FIELD_PRESSURE).EQ.1) THEN
        CALL clover_pack_message_bottom_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%pressure,                 &
          chunk%bottom_snd_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_PRESSURE)+t_offset)

      ENDIF
      IF(fields(FIELD_VISCOSITY).EQ.1) THEN
        CALL clover_pack_message_bottom_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%viscosity,                &
          chunk%bottom_snd_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_VISCOSITY)+t_offset)

      ENDIF
      IF(fields(FIELD_SOUNDSPEED).EQ.1) THEN
        CALL clover_pack_message_bottom_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%soundspeed,               &
          chunk%bottom_snd_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_SOUNDSPEED)+t_offset)

      ENDIF
      IF(fields(FIELD_XVEL0).EQ.1) THEN
        CALL clover_pack_message_bottom_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%xvel0,                    &
          chunk%bottom_snd_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          bottom_top_offset(FIELD_XVEL0)+t_offset)

      ENDIF
      IF(fields(FIELD_XVEL1).EQ.1) THEN
        CALL clover_pack_message_bottom_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%xvel1,                    &
          chunk%bottom_snd_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          bottom_top_offset(FIELD_XVEL1)+t_offset)

      ENDIF
      IF(fields(FIELD_YVEL0).EQ.1) THEN
        CALL clover_pack_message_bottom_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%yvel0,                    &
          chunk%bottom_snd_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          bottom_top_offset(FIELD_YVEL0)+t_offset)

      ENDIF
      IF(fields(FIELD_YVEL1).EQ.1) THEN
        CALL clover_pack_message_bottom_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%yvel1,                    &
          chunk%bottom_snd_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          bottom_top_offset(FIELD_YVEL1)+t_offset)

      ENDIF
      IF(fields(FIELD_VOL_FLUX_X).EQ.1) THEN
        CALL clover_pack_message_bottom_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%vol_flux_x,               &
          chunk%bottom_snd_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, X_FACE_DATA,                           &
          bottom_top_offset(FIELD_VOL_FLUX_X)+t_offset)

      ENDIF
      IF(fields(FIELD_VOL_FLUX_Y).EQ.1) THEN
        CALL clover_pack_message_bottom_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%vol_flux_y,               &
          chunk%bottom_snd_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, Y_FACE_DATA,                           &
          bottom_top_offset(FIELD_VOL_FLUX_Y)+t_offset)

      ENDIF
      IF(fields(FIELD_MASS_FLUX_X).EQ.1) THEN
        CALL clover_pack_message_bottom_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%mass_flux_x,              &
          chunk%bottom_snd_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, X_FACE_DATA,                           &
          bottom_top_offset(FIELD_MASS_FLUX_X)+t_offset)

      ENDIF
      IF(fields(FIELD_MASS_FLUX_Y).EQ.1) THEN
        CALL clover_pack_message_bottom_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%mass_flux_y,              &
          chunk%bottom_snd_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, Y_FACE_DATA,                           &
          bottom_top_offset(FIELD_MASS_FLUX_Y)+t_offset)

      ENDIF
    ENDIF
  
  END SUBROUTINE clover_pack_bottom

  SUBROUTINE clover_send_recv_message_bottom(bottom_snd_buffer, bottom_rcv_buffer,        &
                                             total_size,                           &
                                             tag_send, tag_recv,                          &
                                             req_send, req_recv)

    IMPLICIT NONE

    REAL(KIND=8), POINTER :: bottom_snd_buffer(:), bottom_rcv_buffer(:)
    integer(c_int)      :: bottom_task
    integer(c_int)      :: total_size, tag_send, tag_recv, err
    integer(c_int)      :: req_send, req_recv
    ! i added
    type(c_ptr) :: ptr_snd, ptr_rec
    integer :: status(MPI_STATUS_SIZE)

    bottom_task=chunk%chunk_neighbours(chunk_bottom) - 1

    ! CALL MPI_ISEND(bottom_snd_buffer,total_size,MPI_DOUBLE_PRECISION,bottom_task,tag_send &
    !   ,MPI_COMM_WORLD,req_send,err)

    ptr_snd = c_loc(bottom_snd_buffer)
    CALL my_MPI_Isend(ptr_snd, total_size,MPI_DOUBLE_PRECISION,bottom_task,tag_send &
      ,MPI_COMM_WORLD,req_send,err)

    ! CALL my_MPI_Send(ptr_snd, total_size,MPI_DOUBLE_PRECISION,bottom_task,tag_send &
    !   ,MPI_COMM_WORLD,err)

    ! CALL MPI_IRECV(bottom_rcv_buffer,total_size,MPI_DOUBLE_PRECISION,bottom_task,tag_recv &
    !   ,MPI_COMM_WORLD,req_recv,err)

    ptr_rec = c_loc(bottom_rcv_buffer)
    CALL my_MPI_Irecv(ptr_rec, total_size,MPI_DOUBLE_PRECISION,bottom_task,tag_recv &
      ,MPI_COMM_WORLD,req_recv,err)

    ! CALL my_MPI_Recv(ptr_rec,total_size,MPI_DOUBLE_PRECISION,bottom_task,tag_recv &
    !   ,MPI_COMM_WORLD,status,err)

    ! call my_MPI_Sendrecv(ptr_snd, total_size, MPI_DOUBLE_PRECISION, bottom_task, tag_send, &
    !                     ptr_rec, total_size, MPI_DOUBLE_PRECISION, bottom_task, tag_recv, &
    !                     MPI_COMM_WORLD, status, err)    

  END SUBROUTINE clover_send_recv_message_bottom

  SUBROUTINE clover_unpack_bottom(fields, tile, depth,                        &
                                  bottom_rcv_buffer,                              &
                                  bottom_top_offset)

    USE pack_kernel_module

    IMPLICIT NONE

    integer(c_int)         :: fields(:), tile, depth, bottom_top_offset(:), t_offset
    REAL(KIND=8)    :: bottom_rcv_buffer(:)
  
    t_offset = (chunk%tiles(tile)%t_left - chunk%left)*depth
    IF(use_fortran_kernels) THEN
      IF(fields(FIELD_DENSITY0).EQ.1) THEN
        CALL clover_unpack_message_bottom(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%density0,                 &
          chunk%bottom_rcv_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_DENSITY0)+t_offset)

      ENDIF
      IF(fields(FIELD_DENSITY1).EQ.1) THEN
        CALL clover_unpack_message_bottom(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%density1,                 &
          chunk%bottom_rcv_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_DENSITY1)+t_offset)

      ENDIF
      IF(fields(FIELD_ENERGY0).EQ.1) THEN
        CALL clover_unpack_message_bottom(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%energy0,                  &
          chunk%bottom_rcv_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_ENERGY0)+t_offset)

      ENDIF
      IF(fields(FIELD_ENERGY1).EQ.1) THEN
        CALL clover_unpack_message_bottom(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%energy1,                  &
          chunk%bottom_rcv_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_ENERGY1)+t_offset)

      ENDIF
      IF(fields(FIELD_PRESSURE).EQ.1) THEN
        CALL clover_unpack_message_bottom(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%pressure,                 &
          chunk%bottom_rcv_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_PRESSURE)+t_offset)

      ENDIF
      IF(fields(FIELD_VISCOSITY).EQ.1) THEN
        CALL clover_unpack_message_bottom(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%viscosity,                &
          chunk%bottom_rcv_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_VISCOSITY)+t_offset)

      ENDIF
      IF(fields(FIELD_SOUNDSPEED).EQ.1) THEN
        CALL clover_unpack_message_bottom(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%soundspeed,               &
          chunk%bottom_rcv_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_SOUNDSPEED)+t_offset)

      ENDIF
      IF(fields(FIELD_XVEL0).EQ.1) THEN
        CALL clover_unpack_message_bottom(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%xvel0,                    &
          chunk%bottom_rcv_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          bottom_top_offset(FIELD_XVEL0)+t_offset)

      ENDIF
      IF(fields(FIELD_XVEL1).EQ.1) THEN
        CALL clover_unpack_message_bottom(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%xvel1,                    &
          chunk%bottom_rcv_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          bottom_top_offset(FIELD_XVEL1)+t_offset)

      ENDIF
      IF(fields(FIELD_YVEL0).EQ.1) THEN
        CALL clover_unpack_message_bottom(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%yvel0,                    &
          chunk%bottom_rcv_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          bottom_top_offset(FIELD_YVEL0)+t_offset)

      ENDIF
      IF(fields(FIELD_YVEL1).EQ.1) THEN
        CALL clover_unpack_message_bottom(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%yvel1,                    &
          chunk%bottom_rcv_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          bottom_top_offset(FIELD_YVEL1)+t_offset)

      ENDIF
      IF(fields(FIELD_VOL_FLUX_X).EQ.1) THEN
        CALL clover_unpack_message_bottom(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%vol_flux_x,               &
          chunk%bottom_rcv_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, X_FACE_DATA,                           &
          bottom_top_offset(FIELD_VOL_FLUX_X)+t_offset)

      ENDIF
      IF(fields(FIELD_VOL_FLUX_Y).EQ.1) THEN
        CALL clover_unpack_message_bottom(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%vol_flux_y,               &
          chunk%bottom_rcv_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, Y_FACE_DATA,                           &
          bottom_top_offset(FIELD_VOL_FLUX_Y)+t_offset)

      ENDIF
      IF(fields(FIELD_MASS_FLUX_X).EQ.1) THEN
        CALL clover_unpack_message_bottom(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%mass_flux_x,              &
          chunk%bottom_rcv_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, X_FACE_DATA,                           &
          bottom_top_offset(FIELD_MASS_FLUX_X)+t_offset)

      ENDIF
      IF(fields(FIELD_MASS_FLUX_Y).EQ.1) THEN
        CALL clover_unpack_message_bottom(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%mass_flux_y,              &
          chunk%bottom_rcv_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, Y_FACE_DATA,                           &
          bottom_top_offset(FIELD_MASS_FLUX_Y)+t_offset)

      ENDIF

    ELSEIF(use_C_kernels) THEN
      IF(fields(FIELD_DENSITY0).EQ.1) THEN
        CALL clover_unpack_message_bottom_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%density0,                 &
          chunk%bottom_rcv_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_DENSITY0)+t_offset)

      ENDIF
      IF(fields(FIELD_DENSITY1).EQ.1) THEN
        CALL clover_unpack_message_bottom_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%density1,                 &
          chunk%bottom_rcv_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_DENSITY1)+t_offset)

      ENDIF
      IF(fields(FIELD_ENERGY0).EQ.1) THEN
        CALL clover_unpack_message_bottom_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%energy0,                  &
          chunk%bottom_rcv_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_ENERGY0)+t_offset)

      ENDIF
      IF(fields(FIELD_ENERGY1).EQ.1) THEN
        CALL clover_unpack_message_bottom_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%energy1,                  &
          chunk%bottom_rcv_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_ENERGY1)+t_offset)

      ENDIF
      IF(fields(FIELD_PRESSURE).EQ.1) THEN
        CALL clover_unpack_message_bottom_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%pressure,                 &
          chunk%bottom_rcv_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_PRESSURE)+t_offset)

      ENDIF
      IF(fields(FIELD_VISCOSITY).EQ.1) THEN
        CALL clover_unpack_message_bottom_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%viscosity,                &
          chunk%bottom_rcv_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_VISCOSITY)+t_offset)

      ENDIF
      IF(fields(FIELD_SOUNDSPEED).EQ.1) THEN
        CALL clover_unpack_message_bottom_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%soundspeed,               &
          chunk%bottom_rcv_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, CELL_DATA,                             &
          bottom_top_offset(FIELD_SOUNDSPEED)+t_offset)

      ENDIF
      IF(fields(FIELD_XVEL0).EQ.1) THEN
        CALL clover_unpack_message_bottom_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%xvel0,                    &
          chunk%bottom_rcv_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          bottom_top_offset(FIELD_XVEL0)+t_offset)

      ENDIF
      IF(fields(FIELD_XVEL1).EQ.1) THEN
        CALL clover_unpack_message_bottom_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%xvel1,                    &
          chunk%bottom_rcv_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          bottom_top_offset(FIELD_XVEL1)+t_offset)

      ENDIF
      IF(fields(FIELD_YVEL0).EQ.1) THEN
        CALL clover_unpack_message_bottom_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%yvel0,                    &
          chunk%bottom_rcv_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          bottom_top_offset(FIELD_YVEL0)+t_offset)

      ENDIF
      IF(fields(FIELD_YVEL1).EQ.1) THEN
        CALL clover_unpack_message_bottom_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%yvel1,                    &
          chunk%bottom_rcv_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, VERTEX_DATA,                           &
          bottom_top_offset(FIELD_YVEL1)+t_offset)

      ENDIF
      IF(fields(FIELD_VOL_FLUX_X).EQ.1) THEN
        CALL clover_unpack_message_bottom_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%vol_flux_x,               &
          chunk%bottom_rcv_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, X_FACE_DATA,                           &
          bottom_top_offset(FIELD_VOL_FLUX_X)+t_offset)

      ENDIF
      IF(fields(FIELD_VOL_FLUX_Y).EQ.1) THEN
        CALL clover_unpack_message_bottom_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%vol_flux_y,               &
          chunk%bottom_rcv_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, Y_FACE_DATA,                           &
          bottom_top_offset(FIELD_VOL_FLUX_Y)+t_offset)

      ENDIF
      IF(fields(FIELD_MASS_FLUX_X).EQ.1) THEN
        CALL clover_unpack_message_bottom_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%mass_flux_x,              &
          chunk%bottom_rcv_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, X_FACE_DATA,                           &
          bottom_top_offset(FIELD_MASS_FLUX_X)+t_offset)

      ENDIF
      IF(fields(FIELD_MASS_FLUX_Y).EQ.1) THEN
        CALL clover_unpack_message_bottom_c(chunk%tiles(tile)%t_xmin,                    &
          chunk%tiles(tile)%t_xmax,                    &
          chunk%tiles(tile)%t_ymin,                    &
          chunk%tiles(tile)%t_ymax,                    &
          chunk%tiles(tile)%field%mass_flux_y,              &
          chunk%bottom_rcv_buffer,              &
          CELL_DATA,VERTEX_DATA,X_FACE_DATA,Y_FACE_DATA,&
          depth, Y_FACE_DATA,                           &
          bottom_top_offset(FIELD_MASS_FLUX_Y)+t_offset)

      ENDIF

    ENDIF
  
  END SUBROUTINE clover_unpack_bottom

  SUBROUTINE clover_sum(value)

    ! Only sums to the master

    IMPLICIT NONE

    REAL(KIND=8), target:: value

    REAL(KIND=8), target :: total

    integer(c_int) :: err

    type(C_PTR) :: ptr_val, ptr_total

    total=value

    ptr_val = c_loc(value)
    ptr_total = c_loc(total)

    CALL my_MPI_Reduce(ptr_val,ptr_total,1,MPI_DOUBLE_PRECISION,MPI_SUM,0,MPI_COMM_WORLD,err)

    value=total

  END SUBROUTINE clover_sum

  SUBROUTINE clover_min(value)

    IMPLICIT NONE

    REAL(KIND=8), target :: value

    REAL(KIND=8), target :: minimum

    integer(c_int) :: err

    type(C_PTR) :: ptr_val, ptr_min

    minimum=value

    ptr_val = c_loc(value)
    ptr_min = c_loc(minimum)

    CALL my_MPI_Allreduce(ptr_val,ptr_min,1,MPI_DOUBLE_PRECISION,MPI_MIN,MPI_COMM_WORLD,err)

    value=minimum

  END SUBROUTINE clover_min

  SUBROUTINE clover_max(value)

    IMPLICIT NONE

    REAL(KIND=8), target :: value

    REAL(KIND=8), target :: maximum

    integer(c_int) :: err

    type(C_PTR) :: ptr_val, ptr_max

    maximum=value

    ptr_val = c_loc(value)
    ptr_max = c_loc(maximum)

    CALL my_MPI_Allreduce(ptr_val,ptr_max,1,MPI_DOUBLE_PRECISION,MPI_MAX,MPI_COMM_WORLD,err)

    value=maximum

  END SUBROUTINE clover_max

  SUBROUTINE clover_allgather(value,values)

    IMPLICIT NONE

    REAL(KIND=8) :: value

    REAL(KIND=8) :: values(parallel%max_task)

    integer(c_int) :: err

    values(1)=value ! Just to ensure it will work in serial

    CALL MPI_ALLGATHER(value,1,MPI_DOUBLE_PRECISION,values,1,MPI_DOUBLE_PRECISION,MPI_COMM_WORLD,err)

  END SUBROUTINE clover_allgather

  SUBROUTINE clover_check_error(error)

    IMPLICIT NONE

    integer(c_int), target :: error

    integer(c_int), target :: maximum

    integer(c_int) :: err

    type(C_PTR) :: ptr_val, ptr_max

    maximum=error

    ptr_val = c_loc(error)
    ptr_max = c_loc(maximum)

    CALL MPI_ALLREDUCE(ptr_val,ptr_max,1,MPI_INTEGER,MPI_MAX,MPI_COMM_WORLD,err)

    error=maximum

  END SUBROUTINE clover_check_error


END MODULE clover_module
